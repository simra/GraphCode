import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

#if os(Windows)
  import WinSDK
#endif
enum SafeLocalFile {
  static func validateDirectory(_ url: URL) throws {
    #if os(Windows)
      var path = Array(url.path.utf16)
      path.append(0)
      let handle = path.withUnsafeBufferPointer {
        CreateFileW(
          $0.baseAddress,
          DWORD(GENERIC_READ),
          DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil)
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw RemoteAssetError.unsafeFile
      }
      defer { _ = CloseHandle(handle) }
      var info = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &info),
        info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
        info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
      else { throw RemoteAssetError.unsafeFile }
    #else
      let descriptor = url.path.withCString { path in
        #if canImport(Darwin)
          Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        #else
          Glibc.open(path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        #endif
      }
      guard descriptor >= 0 else { throw RemoteAssetError.unsafeFile }
      defer {
        #if canImport(Darwin)
          _ = Darwin.close(descriptor)
        #else
          _ = Glibc.close(descriptor)
        #endif
      }
      var info = stat()
      guard fstat(descriptor, &info) == 0,
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
      else { throw RemoteAssetError.unsafeFile }
    #endif
  }

  static func read(_ url: URL, maximumBytes: Int) throws -> Data {
    #if os(Windows)
      var path = Array(url.path.utf16)
      path.append(0)
      let handle = path.withUnsafeBufferPointer {
        CreateFileW(
          $0.baseAddress,
          DWORD(GENERIC_READ),
          DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_ATTRIBUTE_NORMAL) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil)
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw RemoteAssetError.unsafeFile
      }
      defer { _ = CloseHandle(handle) }
      var info = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &info),
        info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
        info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
        info.nNumberOfLinks == 1
      else { throw RemoteAssetError.unsafeFile }
      let fileSize = (UInt64(info.nFileSizeHigh) << 32) | UInt64(info.nFileSizeLow)
      guard fileSize <= UInt64(maximumBytes) else { throw RemoteAssetError.oversized }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumBytes + 1))
      while true {
        var count: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes {
          ReadFile(handle, $0.baseAddress, DWORD($0.count), &count, nil)
        }
        guard succeeded else { throw RemoteAssetError.unsafeFile }
        guard count > 0 else { break }
        data.append(contentsOf: buffer.prefix(Int(count)))
        guard data.count <= maximumBytes else { throw RemoteAssetError.oversized }
      }
      return data
    #else
      let descriptor = url.path.withCString { path in
        #if canImport(Darwin)
          Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        #else
          Glibc.open(path, O_RDONLY | O_NOFOLLOW)
        #endif
      }
      guard descriptor >= 0 else { throw RemoteAssetError.unsafeFile }
      defer {
        #if canImport(Darwin)
          _ = Darwin.close(descriptor)
        #else
          _ = Glibc.close(descriptor)
        #endif
      }
      var info = stat()
      guard fstat(descriptor, &info) == 0,
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        info.st_nlink == 1,
        info.st_size >= 0,
        Int64(info.st_size) <= Int64(maximumBytes)
      else { throw RemoteAssetError.unsafeFile }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumBytes + 1))
      while true {
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
          #if canImport(Darwin)
            Darwin.read(descriptor, raw.baseAddress, raw.count)
          #else
            Glibc.read(descriptor, raw.baseAddress, raw.count)
          #endif
        }
        guard count >= 0 else { throw RemoteAssetError.unsafeFile }
        guard count > 0 else { break }
        data.append(contentsOf: buffer.prefix(count))
        guard data.count <= maximumBytes else { throw RemoteAssetError.oversized }
      }
      return data
    #endif
  }
}
