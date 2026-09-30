import Foundation

#if os(Windows)
  import WinSDK
#elseif canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

final class StableProjectDirectory {
  let identityToken: String

  #if os(Windows)
    private let handle: HANDLE

    init(path: String) throws {
      let opened = path.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(DELETE) | DWORD(FILE_READ_ATTRIBUTES),
          DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil)
      }
      guard let opened, opened != INVALID_HANDLE_VALUE else {
        throw StableProjectDirectory.mapWindowsError(GetLastError())
      }
      handle = opened
      do {
        identityToken = try Self.identityToken(handle: opened)
        try Self.rejectReparsePoint(handle: opened)
      } catch {
        _ = CloseHandle(opened)
        throw error
      }
    }

    deinit {
      _ = CloseHandle(handle)
    }

    func verify(path: String) throws {
      let current = try StableProjectDirectory(path: path)
      guard current.identityToken == identityToken else {
        throw ProjectRelocationError.sourceIdentityChanged
      }
    }

    func rename(to destinationPath: String) throws {
      let windowsDestination = destinationPath.replacingOccurrences(of: "/", with: "\\")
      let destinationNT: String
      if let unc = windowsDestination.removingPrefix("\\\\") {
        destinationNT = "\\??\\UNC\\\(unc)"
      } else {
        destinationNT = "\\??\\\(windowsDestination)"
      }
      let wide = Array(destinationNT.utf16)
      guard
        let fileNameOffset = MemoryLayout<FILE_RENAME_INFO>.offset(of: \.FileName),
        wide.count <= Int(DWORD.max) / MemoryLayout<WCHAR>.size
      else {
        throw ProjectRelocationError.unsafePath
      }
      let fileNameBytes = wide.count * MemoryLayout<WCHAR>.size
      let byteCount = MemoryLayout<FILE_RENAME_INFO>.size + fileNameBytes
      let storage = UnsafeMutableRawPointer.allocate(
        byteCount: byteCount,
        alignment: MemoryLayout<FILE_RENAME_INFO>.alignment)
      defer { storage.deallocate() }
      storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
      let rename = storage.assumingMemoryBound(to: FILE_RENAME_INFO.self)
      rename.pointee.ReplaceIfExists = 0
      rename.pointee.RootDirectory = nil
      rename.pointee.FileNameLength = DWORD(fileNameBytes)
      wide.withUnsafeBytes { bytes in
        guard let source = bytes.baseAddress else { return }
        storage.advanced(by: fileNameOffset).copyMemory(
          from: source, byteCount: fileNameBytes)
      }
      guard
        SetFileInformationByHandle(
          handle,
          FileRenameInfo,
          storage,
          DWORD(byteCount))
      else {
        let code = GetLastError()
        throw Self.mapWindowsError(code)
      }
    }

    static func inspectDestinationParent(_ path: String) throws {
      for ancestor in windowsAncestors(through: path) {
        let opened = ancestor.withCString(encodedAs: UTF16.self) {
          CreateFileW(
            $0,
            DWORD(FILE_READ_ATTRIBUTES),
            DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
            nil,
            DWORD(OPEN_EXISTING),
            DWORD(FILE_FLAG_BACKUP_SEMANTICS) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
            nil)
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else {
          throw mapWindowsError(GetLastError())
        }
        defer { _ = CloseHandle(opened) }
        try rejectReparsePoint(handle: opened)
      }
    }

    private static func windowsAncestors(through path: String) -> [String] {
      let normalized = path.replacingOccurrences(of: "/", with: "\\")
      if normalized.hasPrefix("\\\\") {
        let parts = normalized.split(separator: "\\").map(String.init)
        guard parts.count >= 2 else { return [normalized] }
        var current = "\\\\\(parts[0])\\\(parts[1])"
        var result = [current]
        for part in parts.dropFirst(2) {
          current += "\\\(part)"
          result.append(current)
        }
        return result
      }
      guard normalized.count >= 3 else { return [normalized] }
      let root = String(normalized.prefix(3))
      var current = root.trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
      var result = [root]
      for part in normalized.dropFirst(3).split(separator: "\\") {
        current += "\\\(part)"
        result.append(current)
      }
      return result
    }

    private static func rejectReparsePoint(handle: HANDLE) throws {
      var info = FILE_ATTRIBUTE_TAG_INFO()
      guard
        GetFileInformationByHandleEx(
          handle,
          FileAttributeTagInfo,
          &info,
          DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size))
      else {
        throw mapWindowsError(GetLastError())
      }
      guard info.FileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw ProjectRelocationError.unsafePath
      }
    }

    private static func identityToken(handle: HANDLE) throws -> String {
      var info = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &info) else {
        throw mapWindowsError(GetLastError())
      }
      return GraphcodeSHA256.hex(
        Data(
          "\(info.dwVolumeSerialNumber):\(info.nFileIndexHigh):\(info.nFileIndexLow)".utf8))
    }

    private static func mapWindowsError(_ code: DWORD) -> ProjectRelocationError {
      switch code {
      case DWORD(ERROR_ACCESS_DENIED), DWORD(ERROR_SHARING_VIOLATION):
        return .permissionDenied
      case DWORD(ERROR_FILE_EXISTS), DWORD(ERROR_ALREADY_EXISTS):
        return .destinationCollision
      case DWORD(ERROR_FILE_NOT_FOUND), DWORD(ERROR_PATH_NOT_FOUND):
        return .sourceMissing
      case DWORD(ERROR_NOT_SAME_DEVICE):
        return .crossVolume
      default:
        return .preflightFailed
      }
    }
  #else
    private let descriptor: Int32
    private let sourcePath: String

    init(path: String) throws {
      let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      guard opened >= 0 else { throw ProjectRelocationError.unsafePath }
      descriptor = opened
      sourcePath = path
      do {
        identityToken = try Self.identityToken(descriptor: opened)
      } catch {
        close(opened)
        throw error
      }
    }

    deinit {
      close(descriptor)
    }

    func verify(path: String) throws {
      let current = try StableProjectDirectory(path: path)
      guard current.identityToken == identityToken else {
        throw ProjectRelocationError.sourceIdentityChanged
      }
    }

    func rename(to destinationPath: String) throws {
      try verify(path: sourcePath)
      #if canImport(Darwin)
        guard
          renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_EXCL)) == 0
        else {
          if errno == EEXIST { throw ProjectRelocationError.destinationCollision }
          if errno == EXDEV { throw ProjectRelocationError.crossVolume }
          if errno == EACCES || errno == EPERM { throw ProjectRelocationError.permissionDenied }
          throw ProjectRelocationError.preflightFailed
        }
      #else
        guard !FileManager.default.fileExists(atPath: destinationPath) else {
          throw ProjectRelocationError.destinationCollision
        }
        try FileManager.default.moveItem(
          at: URL(fileURLWithPath: sourcePath),
          to: URL(fileURLWithPath: destinationPath))
      #endif
    }

    static func inspectDestinationParent(_ path: String) throws {
      let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      guard opened >= 0 else { throw ProjectRelocationError.unsafePath }
      close(opened)
    }

    private static func identityToken(descriptor: Int32) throws -> String {
      var info = stat()
      guard fstat(descriptor, &info) == 0 else {
        throw ProjectRelocationError.preflightFailed
      }
      return GraphcodeSHA256.hex(Data("\(info.st_dev):\(info.st_ino)".utf8))
    }
  #endif
}
extension String {
  fileprivate func removingPrefix(_ prefix: String) -> String? {
    guard hasPrefix(prefix) else { return nil }
    return String(dropFirst(prefix.count))
  }
}
