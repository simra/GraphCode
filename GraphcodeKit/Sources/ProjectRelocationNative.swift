import Foundation

#if os(Windows)
  import WinSDK
#endif

enum ProjectRelocationPlatform {
  #if os(Windows)
    static let isSupported = true
  #else
    static let isSupported = false
  #endif
}

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
    init(path _: String) throws {
      throw ProjectRelocationError.unsupported
    }

    func verify(path _: String) throws {
      throw ProjectRelocationError.unsupported
    }

    func rename(to _: String) throws {
      throw ProjectRelocationError.unsupported
    }

    static func inspectDestinationParent(_: String) throws {
      throw ProjectRelocationError.unsupported
    }
  #endif
}

final class StableRelocationGenerationDirectory {
  #if os(Windows)
    private let parentHandle: HANDLE
    private let directoryHandle: HANDLE
    private let entryName: String
    private let identity: FileIdentity

    private struct FileIdentity: Equatable {
      var volume: DWORD
      var high: DWORD
      var low: DWORD
    }

    private typealias NtCreateFileFunction =
      @convention(c) (
        UnsafeMutablePointer<HANDLE?>?,
        ACCESS_MASK,
        UnsafeMutablePointer<OBJECT_ATTRIBUTES>?,
        UnsafeMutablePointer<IO_STATUS_BLOCK>?,
        UnsafeMutablePointer<LARGE_INTEGER>?,
        ULONG,
        ULONG,
        ULONG,
        ULONG,
        UnsafeMutableRawPointer?,
        ULONG
      ) -> NTSTATUS

    init(parentPath: String, entryName: String, deletable: Bool) throws {
      guard !entryName.isEmpty, !entryName.contains("\\"),
        !entryName.contains("/"), entryName != ".", entryName != ".."
      else {
        throw ProjectRelocationError.recoveryFailed
      }
      self.entryName = entryName
      parentHandle = try Self.openAbsoluteDirectory(parentPath)
      do {
        directoryHandle = try Self.openRelative(
          root: parentHandle, name: entryName, directory: true,
          deletable: deletable, shareDelete: false)
        identity = try Self.validateDirectory(directoryHandle)
      } catch {
        _ = CloseHandle(parentHandle)
        throw error
      }
    }

    deinit {
      _ = CloseHandle(directoryHandle)
      _ = CloseHandle(parentHandle)
    }

    func remove(expectedName: (String) -> Bool, maximumFileBytes: UInt64) throws {
      try ensureCurrentEntry()
      let names = try enumerateNames()
      guard names.count <= 4_096 else {
        throw ProjectRelocationError.recoveryFailed
      }
      for name in names {
        guard expectedName(name) else {
          throw ProjectRelocationError.recoveryFailed
        }
        let child = try Self.openRelative(
          root: directoryHandle, name: name, directory: false,
          deletable: true, shareDelete: false)
        do {
          try Self.validateAndReadFile(child, maximumBytes: maximumFileBytes)
          try Self.markForDeletion(child)
        } catch {
          _ = CloseHandle(child)
          throw error
        }
        _ = CloseHandle(child)
      }
      guard try enumerateNames().isEmpty else {
        throw ProjectRelocationError.recoveryFailed
      }
      try ensureCurrentEntry()
      try Self.markForDeletion(directoryHandle)
    }

    func ensureCurrentEntry() throws {
      let current: HANDLE
      do {
        current = try Self.openRelative(
          root: parentHandle, name: entryName, directory: true,
          deletable: false, shareDelete: true)
      } catch {
        throw ProjectRelocationError.sourceIdentityChanged
      }
      defer { _ = CloseHandle(current) }
      guard try Self.validateDirectory(current) == identity else {
        throw ProjectRelocationError.sourceIdentityChanged
      }
    }

    func hasSameIdentity(as other: StableRelocationGenerationDirectory) -> Bool {
      identity == other.identity
    }

    private func enumerateNames() throws -> [String] {
      guard
        let fileNameOffset = MemoryLayout<FILE_ID_BOTH_DIR_INFO>.offset(of: \.FileName)
      else {
        throw ProjectRelocationError.recoveryFailed
      }
      var names: [String] = []
      var restart = true
      let storage = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1_024, alignment: 8)
      defer { storage.deallocate() }
      while true {
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: 64 * 1_024)
        let infoClass: FILE_INFO_BY_HANDLE_CLASS =
          restart ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo
        guard
          GetFileInformationByHandleEx(
            directoryHandle, infoClass, storage, DWORD(64 * 1_024))
        else {
          let error = GetLastError()
          if error == DWORD(ERROR_NO_MORE_FILES) { break }
          throw Self.mapWindowsError(error)
        }
        restart = false
        var offset = 0
        while true {
          let record = storage.advanced(by: offset)
            .assumingMemoryBound(to: FILE_ID_BOTH_DIR_INFO.self)
          let byteCount = Int(record.pointee.FileNameLength)
          guard byteCount >= 0, byteCount % MemoryLayout<WCHAR>.size == 0,
            byteCount <= 64 * 1_024 - offset - fileNameOffset
          else {
            throw ProjectRelocationError.recoveryFailed
          }
          let units = record.advanced(by: 0).withMemoryRebound(
            to: WCHAR.self, capacity: byteCount / MemoryLayout<WCHAR>.size
          ) { pointer in
            UnsafeBufferPointer(
              start: UnsafeRawPointer(pointer).advanced(by: fileNameOffset)
                .assumingMemoryBound(to: WCHAR.self),
              count: byteCount / MemoryLayout<WCHAR>.size)
          }
          let name = String(decoding: units, as: UTF16.self)
          if name != ".", name != ".." {
            guard !name.isEmpty, !name.contains("\\"), !name.contains("/") else {
              throw ProjectRelocationError.recoveryFailed
            }
            names.append(name)
          }
          let next = Int(record.pointee.NextEntryOffset)
          if next == 0 { break }
          guard next > 0, offset + next < 64 * 1_024 else {
            throw ProjectRelocationError.recoveryFailed
          }
          offset += next
        }
      }
      return names
    }

    private static func openAbsoluteDirectory(_ path: String) throws -> HANDLE {
      let opened = path.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(FILE_LIST_DIRECTORY) | DWORD(FILE_READ_ATTRIBUTES) | DWORD(SYNCHRONIZE),
          DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil)
      }
      guard let opened, opened != INVALID_HANDLE_VALUE else {
        throw mapWindowsError(GetLastError())
      }
      do {
        _ = try validateDirectory(opened)
        return opened
      } catch {
        _ = CloseHandle(opened)
        throw error
      }
    }

    private static func openRelative(
      root: HANDLE, name: String, directory: Bool, deletable: Bool,
      shareDelete: Bool
    ) throws -> HANDLE {
      var wide = Array(name.utf16)
      guard !wide.isEmpty,
        wide.count <= Int(UInt16.max) / MemoryLayout<WCHAR>.size
      else {
        throw ProjectRelocationError.recoveryFailed
      }
      return try wide.withUnsafeMutableBufferPointer { buffer in
        var objectName = UNICODE_STRING(
          Length: USHORT(buffer.count * MemoryLayout<WCHAR>.size),
          MaximumLength: USHORT(buffer.count * MemoryLayout<WCHAR>.size),
          Buffer: buffer.baseAddress)
        return try withUnsafeMutablePointer(to: &objectName) { namePointer in
          var attributes = OBJECT_ATTRIBUTES(
            Length: ULONG(MemoryLayout<OBJECT_ATTRIBUTES>.size),
            RootDirectory: root,
            ObjectName: namePointer,
            Attributes: ULONG(OBJ_CASE_INSENSITIVE),
            SecurityDescriptor: nil,
            SecurityQualityOfService: nil)
          var status = IO_STATUS_BLOCK()
          var opened: HANDLE?
          let access =
            (deletable ? DWORD(DELETE) : 0) | DWORD(FILE_READ_ATTRIBUTES) | DWORD(SYNCHRONIZE)
            | (directory ? DWORD(FILE_LIST_DIRECTORY) : DWORD(GENERIC_READ))
          let sharing =
            ULONG(FILE_SHARE_READ) | ULONG(FILE_SHARE_WRITE)
            | (shareDelete ? ULONG(FILE_SHARE_DELETE) : 0)
          let options =
            ULONG(FILE_OPEN_REPARSE_POINT) | ULONG(FILE_SYNCHRONOUS_IO_NONALERT)
            | (directory ? ULONG(FILE_DIRECTORY_FILE) : ULONG(FILE_NON_DIRECTORY_FILE))
          let result = try ntCreateFile()(
            &opened, access, &attributes, &status, nil, 0,
            sharing,
            ULONG(FILE_OPEN), options, nil, 0)
          guard result >= 0, let opened, opened != INVALID_HANDLE_VALUE else {
            throw ProjectRelocationError.recoveryFailed
          }
          return opened
        }
      }
    }

    private static func ntCreateFile() throws -> NtCreateFileFunction {
      let module = "ntdll.dll".withCString(encodedAs: UTF16.self) {
        GetModuleHandleW($0)
      }
      guard let module,
        let address = "NtCreateFile".withCString({ GetProcAddress(module, $0) })
      else {
        throw ProjectRelocationError.unsupported
      }
      return unsafeBitCast(address, to: NtCreateFileFunction.self)
    }

    private static func validateDirectory(_ handle: HANDLE) throws -> FileIdentity {
      var info = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &info),
        info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
        info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      else {
        throw ProjectRelocationError.recoveryFailed
      }
      return FileIdentity(
        volume: info.dwVolumeSerialNumber,
        high: info.nFileIndexHigh,
        low: info.nFileIndexLow)
    }

    private static func validateAndReadFile(
      _ handle: HANDLE, maximumBytes: UInt64
    ) throws {
      var info = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &info),
        info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
        info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
        info.nNumberOfLinks == 1
      else {
        throw ProjectRelocationError.recoveryFailed
      }
      let size = (UInt64(info.nFileSizeHigh) << 32) | UInt64(info.nFileSizeLow)
      guard size <= maximumBytes else {
        throw ProjectRelocationError.recoveryFailed
      }
      var total: UInt64 = 0
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      while true {
        var read: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes {
          ReadFile(handle, $0.baseAddress, DWORD($0.count), &read, nil)
        }
        guard succeeded else {
          throw ProjectRelocationError.recoveryFailed
        }
        guard read > 0 else { break }
        total += UInt64(read)
        guard total <= maximumBytes else {
          throw ProjectRelocationError.recoveryFailed
        }
      }
      guard total == size else {
        throw ProjectRelocationError.recoveryFailed
      }
    }

    private static func markForDeletion(_ handle: HANDLE) throws {
      var disposition = FILE_DISPOSITION_INFO_EX(
        Flags: DWORD(FILE_DISPOSITION_FLAG_DELETE)
          | DWORD(FILE_DISPOSITION_FLAG_POSIX_SEMANTICS)
          | DWORD(FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE))
      guard
        SetFileInformationByHandle(
          handle, FileDispositionInfoEx, &disposition,
          DWORD(MemoryLayout<FILE_DISPOSITION_INFO_EX>.size))
      else {
        throw mapWindowsError(GetLastError())
      }
    }

    private static func mapWindowsError(_ code: DWORD) -> ProjectRelocationError {
      switch code {
      case DWORD(ERROR_ACCESS_DENIED), DWORD(ERROR_SHARING_VIOLATION):
        return .permissionDenied
      case DWORD(ERROR_FILE_NOT_FOUND), DWORD(ERROR_PATH_NOT_FOUND):
        return .sourceMissing
      default:
        return .recoveryFailed
      }
    }
  #else
    init(parentPath _: String, entryName _: String, deletable _: Bool) throws {
      throw ProjectRelocationError.unsupported
    }

    func remove(
      expectedName _: (String) -> Bool, maximumFileBytes _: UInt64
    ) throws {
      throw ProjectRelocationError.unsupported
    }

    func ensureCurrentEntry() throws {
      throw ProjectRelocationError.unsupported
    }

    func hasSameIdentity(as _: StableRelocationGenerationDirectory) -> Bool {
      false
    }
  #endif
}

extension String {
  fileprivate func removingPrefix(_ prefix: String) -> String? {
    guard hasPrefix(prefix) else { return nil }
    return String(dropFirst(prefix.count))
  }
}
