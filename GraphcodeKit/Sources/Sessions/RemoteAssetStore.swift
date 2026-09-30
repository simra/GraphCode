import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct RemoteAssetHostTransport: Sendable {
  public var templateDocuments:
    @Sendable (_ projectPath: String, _ metadata: ProjectMetadata, _ maximumBytes: Int) async throws
      -> [(origin: TemplateOrigin, fileName: String, content: String)]
  public var stageAttachment:
    @Sendable (
      _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ name: String,
      _ data: Data
    ) async throws -> String
  public var discardAttachments:
    @Sendable (_ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID) async -> Void
  public var resolveAttachment:
    @Sendable (
      _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ name: String,
      _ size: Int, _ sha256: String
    ) async throws -> String
  public var retainAttachments:
    @Sendable (
      _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ names: Set<String>
    ) async throws -> Void

  public init(
    templateDocuments:
      @escaping @Sendable (
        _ projectPath: String, _ metadata: ProjectMetadata, _ maximumBytes: Int
      ) async throws -> [(origin: TemplateOrigin, fileName: String, content: String)],
    stageAttachment:
      @escaping @Sendable (
        _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ name: String,
        _ data: Data
      ) async throws -> String,
    discardAttachments:
      @escaping @Sendable (_ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID) async
      -> Void,
    resolveAttachment:
      @escaping @Sendable (
        _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ name: String,
        _ size: Int, _ sha256: String
      ) async throws -> String,
    retainAttachments:
      @escaping @Sendable (
        _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ names: Set<String>
      ) async throws -> Void
  ) {
    self.templateDocuments = templateDocuments
    self.stageAttachment = stageAttachment
    self.discardAttachments = discardAttachments
    self.resolveAttachment = resolveAttachment
    self.retainAttachments = retainAttachments
  }

  public static let live = RemoteAssetHostTransport(
    templateDocuments: { projectPath, metadata, maximumBytes in
      switch metadata.location {
      case .local:
        return try LocalRemoteAssetHost.templateDocuments(
          projectPath: projectPath, maximumBytes: maximumBytes)
      case .ssh, .codespace:
        return try await SSHRemoteAssetHost.templateDocuments(
          projectPath: projectPath, maximumBytes: maximumBytes)
      }
    },
    stageAttachment: { projectPath, metadata, nodeID, name, data in
      switch metadata.location {
      case .local:
        return try LocalRemoteAssetHost.stageAttachment(
          projectPath: projectPath, nodeID: nodeID, name: name, data: data)
      case .ssh, .codespace:
        return try await SSHRemoteAssetHost.stageAttachment(
          projectPath: projectPath, locationKind: metadata.location, nodeID: nodeID, name: name,
          data: data)
      }
    },
    discardAttachments: { projectPath, metadata, nodeID in
      switch metadata.location {
      case .local:
        LocalRemoteAssetHost.discardAttachments(projectPath: projectPath, nodeID: nodeID)
      case .ssh, .codespace:
        await SSHRemoteAssetHost.discardAttachments(
          projectPath: projectPath, locationKind: metadata.location, nodeID: nodeID)
      }
    },
    resolveAttachment: { projectPath, metadata, nodeID, name, size, sha256 in
      switch metadata.location {
      case .local:
        return try LocalRemoteAssetHost.resolveAttachment(
          projectPath: projectPath, nodeID: nodeID, name: name, size: size, sha256: sha256)
      case .ssh, .codespace:
        return try await SSHRemoteAssetHost.resolveAttachment(
          projectPath: projectPath, locationKind: metadata.location, nodeID: nodeID, name: name,
          size: size, sha256: sha256)
      }
    },
    retainAttachments: { projectPath, metadata, nodeID, names in
      switch metadata.location {
      case .local:
        try LocalRemoteAssetHost.retainAttachments(
          projectPath: projectPath, nodeID: nodeID, names: names)
      case .ssh, .codespace:
        try await SSHRemoteAssetHost.retainAttachments(
          projectPath: projectPath, locationKind: metadata.location, nodeID: nodeID, names: names)
      }
    })
}
public actor RemoteAssetStore {
  public static let maximumChunkBytes = 256 * 1024
  public static let transferLifetime: TimeInterval = 5 * 60

  private struct Transfer: Sendable {
    var owner: UUID
    var projectPath: String
    var metadata: ProjectMetadata
    var nodeID: UUID
    var declaration: AttachmentUploadDeclaration
    var bytes: Data
    var expiresAt: Date
  }

  private struct ReferencePayload: Codable, Equatable, Sendable {
    var version: Int
    var projectIdentity: String
    var nodeID: UUID
    var name: String
    var size: Int
    var sha256: String
  }

  private let transport: RemoteAssetHostTransport
  private let authenticationKey: Data?
  private let now: @Sendable () -> Date
  private var transfers: [UUID: Transfer] = [:]
  private var stagedCounts: [String: Int] = [:]

  public init(
    transport: RemoteAssetHostTransport = .live,
    authenticationKey: Data? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transport = transport
    self.authenticationKey = authenticationKey ?? Self.loadAuthenticationKey()
    self.now = now
  }

  public func listTemplates(
    owner: UUID,
    projectPath: String,
    metadata: ProjectMetadata,
    query: RemoteTemplateListQuery
  ) async -> Result<RemoteTemplateList, RemoteAssetError> {
    _ = owner
    guard metadata.capabilities.templates else { return .failure(.unsupported) }
    do {
      let query = try query.validated()
      let documents = try await transport.templateDocuments(projectPath, metadata, query.maxBytes)
      var templates: [RemoteTemplateMetadata] = []
      var encodedBytes = 0
      for document in documents {
        guard AttachmentUploadDeclaration.isSafeName(document.fileName),
          document.fileName.hasSuffix(".md"),
          document.content.utf8.count <= RemoteTemplateReadQuery.maximumBytes,
          let template = TemplateFileCodec.decode(document.content, origin: document.origin)
        else { continue }
        var normalized = template
        normalized.fileName = document.fileName
        let metadata = RemoteTemplateMetadata(
          id: normalized.id, name: normalized.name, fileName: normalized.fileName,
          origin: normalized.origin)
        encodedBytes += (try? JSONEncoder().encode(metadata).count) ?? query.maxBytes + 1
        guard templates.count < query.maxCount, encodedBytes <= query.maxBytes else { break }
        templates.append(metadata)
      }
      return .success(RemoteTemplateList(projectPath: projectPath, templates: templates))
    } catch let error as RemoteAssetError {
      return .failure(error)
    } catch {
      return .failure(.transportFailure)
    }
  }

  public func readTemplate(
    owner: UUID,
    projectPath: String,
    metadata: ProjectMetadata,
    query: RemoteTemplateReadQuery
  ) async -> Result<RemoteTemplateContent, RemoteAssetError> {
    _ = owner
    guard metadata.capabilities.templates else { return .failure(.unsupported) }
    do {
      let query = try query.validated()
      let documents = try await transport.templateDocuments(projectPath, metadata, query.maxBytes)
      for document in documents {
        guard document.content.utf8.count <= query.maxBytes,
          AttachmentUploadDeclaration.isSafeName(document.fileName),
          let template = TemplateFileCodec.decode(document.content, origin: document.origin),
          template.id == query.templateID
        else { continue }
        var normalized = template
        normalized.fileName = document.fileName
        return .success(RemoteTemplateContent(projectPath: projectPath, template: normalized))
      }
      return .failure(.missing)
    } catch let error as RemoteAssetError {
      return .failure(error)
    } catch {
      return .failure(.transportFailure)
    }
  }

  public func beginUpload(
    owner: UUID,
    projectPath: String,
    metadata: ProjectMetadata,
    nodeID: UUID,
    declaration: AttachmentUploadDeclaration,
    existingCount: Int
  ) -> Result<AttachmentUploadTicket, RemoteAssetError> {
    expireTransfers()
    guard metadata.capabilities.attachments else { return .failure(.unsupported) }
    let key = nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID)
    let activeCount = transfers.values.filter {
      $0.projectPath == projectPath && $0.nodeID == nodeID
    }.count
    guard
      existingCount + activeCount + (stagedCounts[key] ?? 0)
        < AttachmentUploadDeclaration.maximumFilesPerNode
    else {
      return .failure(.tooManyAttachments)
    }
    do {
      let declaration = try declaration.validated()
      let id = UUID()
      let expiresAt = now().addingTimeInterval(Self.transferLifetime)
      transfers[id] = Transfer(
        owner: owner, projectPath: projectPath, metadata: metadata, nodeID: nodeID,
        declaration: declaration, bytes: Data(), expiresAt: expiresAt)
      return .success(
        AttachmentUploadTicket(
          transferID: id, maximumChunkBytes: Self.maximumChunkBytes, expiresAt: expiresAt))
    } catch let error as RemoteAssetError {
      return .failure(error)
    } catch {
      return .failure(.invalidDeclaration)
    }
  }

  public func append(
    owner: UUID, transferID: UUID, offset: Int, data: Data
  ) -> Result<AttachmentUploadProgress, RemoteAssetError> {
    expireTransfers()
    guard var transfer = transfers[transferID], transfer.owner == owner else {
      return .failure(.unknownTransfer)
    }
    guard data.count <= Self.maximumChunkBytes,
      offset == transfer.bytes.count,
      transfer.bytes.count + data.count <= transfer.declaration.size
    else {
      return .failure(data.count > Self.maximumChunkBytes ? .oversized : .invalidOffset)
    }
    transfer.bytes.append(data)
    transfers[transferID] = transfer
    return .success(
      AttachmentUploadProgress(transferID: transferID, nextOffset: transfer.bytes.count))
  }

  public func finalize(
    owner: UUID, transferID: UUID
  ) async -> Result<PromptAttachment, RemoteAssetError> {
    expireTransfers()
    guard let transfer = transfers[transferID], transfer.owner == owner else {
      return .failure(.unknownTransfer)
    }
    guard transfer.bytes.count == transfer.declaration.size else {
      return .failure(.invalidOffset)
    }
    guard Self.sha256Hex(transfer.bytes) == transfer.declaration.sha256.lowercased() else {
      transfers.removeValue(forKey: transferID)
      return .failure(.hashMismatch)
    }
    do {
      _ = try await transport.stageAttachment(
        transfer.projectPath, transfer.metadata, transfer.nodeID, transfer.declaration.name,
        transfer.bytes)
      let reference = try makeReference(
        projectPath: transfer.projectPath, metadata: transfer.metadata, nodeID: transfer.nodeID,
        declaration: transfer.declaration)
      stagedCounts[
        nodeKey(
          projectPath: transfer.projectPath, metadata: transfer.metadata, nodeID: transfer.nodeID),
        default: 0
      ] += 1
      transfers.removeValue(forKey: transferID)
      return .success(
        PromptAttachment(path: reference, name: transfer.declaration.name))
    } catch {
      transfers.removeValue(forKey: transferID)
      return .failure(.transportFailure)
    }
  }

  public func cancel(owner: UUID, transferID: UUID) -> Result<Void, RemoteAssetError> {
    guard let transfer = transfers[transferID], transfer.owner == owner else {
      return .failure(.unknownTransfer)
    }
    transfers.removeValue(forKey: transferID)
    return .success(())
  }

  public func disconnected(owner: UUID) {
    transfers = transfers.filter { $0.value.owner != owner }
  }

  public func consumed(projectPath: String, metadata: ProjectMetadata, nodeID: UUID) {
    stagedCounts.removeValue(
      forKey: nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID))
  }

  public func discard(
    owner: UUID, projectPath: String, metadata: ProjectMetadata, nodeID: UUID
  ) async {
    transfers = transfers.filter {
      !($0.value.owner == owner && $0.value.projectPath == projectPath && $0.value.nodeID == nodeID)
    }
    stagedCounts.removeValue(
      forKey: nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID))
    await transport.discardAttachments(projectPath, metadata, nodeID)
  }

  public func validate(
    _ attachments: [PromptAttachment], projectPath: String, metadata: ProjectMetadata, nodeID: UUID
  ) -> Result<Void, RemoteAssetError> {
    guard attachments.count <= AttachmentUploadDeclaration.maximumFilesPerNode else {
      return .failure(.tooManyAttachments)
    }
    for attachment in attachments {
      guard let payload = try? decodeReference(attachment.path),
        payload.projectIdentity == RemoteAssetIdentity.project(projectPath, metadata),
        payload.nodeID == nodeID,
        payload.name == attachment.fileName
      else { return .failure(.invalidReference) }
    }
    return .success(())
  }

  public func resolvedPath(
    for attachment: PromptAttachment, projectPath: String, nodeID: UUID,
    metadata: ProjectMetadata
  ) async -> Result<String, RemoteAssetError> {
    guard let payload = try? decodeReference(attachment.path),
      payload.projectIdentity == RemoteAssetIdentity.project(projectPath, metadata),
      payload.nodeID == nodeID,
      payload.name == attachment.fileName
    else { return .failure(.invalidReference) }
    do {
      return .success(
        try await transport.resolveAttachment(
          projectPath, metadata, nodeID, payload.name, payload.size, payload.sha256))
    } catch let error as RemoteAssetError {
      return .failure(error)
    } catch {
      return .failure(.transportFailure)
    }
  }

  public func retainOnly(
    _ attachments: [PromptAttachment], projectPath: String, metadata: ProjectMetadata,
    nodeID: UUID
  ) async -> Result<Void, RemoteAssetError> {
    var names: Set<String> = []
    for attachment in attachments {
      guard
        let payload = try? decodeReference(attachment.path),
        payload.projectIdentity == RemoteAssetIdentity.project(projectPath, metadata),
        payload.nodeID == nodeID,
        payload.name == attachment.fileName
      else { return .failure(.invalidReference) }
      names.insert(payload.name)
    }
    do {
      try await transport.retainAttachments(projectPath, metadata, nodeID, names)
      let key = nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID)
      if names.isEmpty {
        stagedCounts.removeValue(forKey: key)
      } else {
        stagedCounts[key] = names.count
      }
      return .success(())
    } catch let error as RemoteAssetError {
      return .failure(error)
    } catch {
      return .failure(.transportFailure)
    }
  }

  public func discardDraftIfStaged(
    projectPath: String, metadata: ProjectMetadata, nodeID: UUID
  ) async -> Result<Void, RemoteAssetError> {
    let key = nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID)
    guard stagedCounts[key] != nil else { return .success(()) }
    await transport.discardAttachments(projectPath, metadata, nodeID)
    stagedCounts.removeValue(forKey: key)
    return .success(())
  }

  private func expireTransfers() {
    let current = now()
    transfers = transfers.filter { $0.value.expiresAt > current }
  }

  private func nodeKey(projectPath: String, metadata: ProjectMetadata, nodeID: UUID) -> String {
    "\(RemoteAssetIdentity.project(projectPath, metadata)):\(nodeID.uuidString)"
  }

  private func makeReference(
    projectPath: String, metadata: ProjectMetadata, nodeID: UUID,
    declaration: AttachmentUploadDeclaration
  ) throws -> String {
    guard let authenticationKey else { throw RemoteAssetError.transportFailure }
    let payload = ReferencePayload(
      version: 1, projectIdentity: RemoteAssetIdentity.project(projectPath, metadata),
      nodeID: nodeID,
      name: declaration.name, size: declaration.size, sha256: declaration.sha256.lowercased())
    let data = try JSONEncoder().encode(payload)
    let signature = Self.hmacSHA256(key: authenticationKey, message: data)
    return
      "\(PromptAttachment.opaqueReferencePrefix)\(Self.base64URL(data)).\(Self.base64URL(signature))"
  }

  private func decodeReference(_ value: String) throws -> ReferencePayload {
    guard let authenticationKey else { throw RemoteAssetError.invalidReference }
    let prefix = PromptAttachment.opaqueReferencePrefix
    guard value.hasPrefix(prefix) else { throw RemoteAssetError.invalidReference }
    let parts = value.dropFirst(prefix.count).split(
      separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, let payload = Self.decodeBase64URL(String(parts[0])),
      let signature = Self.decodeBase64URL(String(parts[1])),
      Self.constantTimeEqual(signature, Self.hmacSHA256(key: authenticationKey, message: payload)),
      let decoded = try? JSONDecoder().decode(ReferencePayload.self, from: payload),
      decoded.version == 1, AttachmentUploadDeclaration.isSafeName(decoded.name),
      decoded.size > 0, decoded.size <= AttachmentUploadDeclaration.maximumFileBytes
    else { throw RemoteAssetError.invalidReference }
    return decoded
  }

  private static func sha256Hex(_ data: Data) -> String {
    GraphcodeSHA256.digest(data).map { String(format: "%02x", $0) }.joined()
  }

  private static func loadAuthenticationKey() -> Data? {
    let url = SupportDirectory.url.appendingPathComponent("remote-assets.key")
    do {
      if FileManager.default.fileExists(atPath: url.path) {
        let values = try url.resourceValues(
          forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let linkCount = (attributes[.referenceCount] as? NSNumber)?.intValue ?? 1
        guard values.isRegularFile == true, values.isSymbolicLink != true, linkCount == 1 else {
          return nil
        }
        let data = try Data(contentsOf: url)
        return data.count >= 32 ? data : nil
      }
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      var bytes = [UInt8](repeating: 0, count: 32)
      for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
      let data = Data(bytes)
      try data.write(to: url, options: [.atomic, .withoutOverwriting])
      #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      #endif
      return try Data(contentsOf: url) == data ? data : nil
    } catch {
      return nil
    }
  }

  private static func hmacSHA256(key: Data, message: Data) -> Data {
    let blockSize = 64
    let sourceKey = Array(key.count > blockSize ? GraphcodeSHA256.digest(key) : key)
    var outer = [UInt8](repeating: 0x5c, count: blockSize)
    var inner = [UInt8](repeating: 0x36, count: blockSize)
    for index in sourceKey.indices {
      outer[index] ^= sourceKey[index]
      inner[index] ^= sourceKey[index]
    }
    let innerDigest = GraphcodeSHA256.digest(Data(inner + Array(message)))
    return GraphcodeSHA256.digest(Data(outer + Array(innerDigest)))
  }

  private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
    return difference == 0
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decodeBase64URL(_ value: String) -> Data? {
    var padded = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
    return Data(base64Encoded: padded)
  }
}

private enum RemoteAssetIdentity {
  static func project(_ path: String, _ metadata: ProjectMetadata) -> String {
    project(path, metadata.location)
  }

  static func project(_ path: String, _ location: ProjectLocationKind) -> String {
    RemoteAssetDigest.sha256Hex(Data("\(location.rawValue)\0\(path)".utf8))
  }
}

enum LocalRemoteAssetHost {
  static func templateDocuments(
    projectPath: String, maximumBytes: Int, storage: TemplateStorage = .shared
  ) throws -> [(origin: TemplateOrigin, fileName: String, content: String)] {
    let locations: [(URL, TemplateOrigin)] = [
      (storage.projectDirectory(projectPath), .project(projectPath)),
      (storage.homeDirectory, .home),
    ]
    var total = 0
    var documents: [(TemplateOrigin, String, String)] = []
    for (directory, origin) in locations {
      guard
        let entries = try? FileManager.default.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
          options: [.skipsHiddenFiles])
      else { continue }
      for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard url.pathExtension == "md",
          let data = try? SafeLocalFile.read(url, maximumBytes: maximumBytes)
        else { continue }
        total += data.count
        guard total <= maximumBytes, let content = String(data: data, encoding: .utf8) else {
          throw RemoteAssetError.oversized
        }
        documents.append((origin, url.lastPathComponent, content))
      }
    }
    return documents
  }

  static func stageAttachment(
    projectPath: String, nodeID: UUID, name: String, data: Data
  ) throws -> String {
    let directory = NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let directoryValues = try directory.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
      throw RemoteAssetError.unsafeFile
    }
    let destination = directory.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: destination.path) {
      throw RemoteAssetError.unsafeFile
    }
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).upload")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.write(to: temporary, options: [.atomic])
    try FileManager.default.moveItem(at: temporary, to: destination)
    return destination.path
  }

  static func discardAttachments(projectPath: String, nodeID: UUID) {
    try? FileManager.default.removeItem(
      at: NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID))
  }

  static func resolveAttachment(
    projectPath: String, nodeID: UUID, name: String, size: Int, sha256: String
  ) throws -> String {
    let directory = NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
    let destination = directory.appendingPathComponent(name)
    let directoryValues = try directory.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
      throw RemoteAssetError.unsafeFile
    }
    let data = try SafeLocalFile.read(destination, maximumBytes: size)
    guard data.count == size, RemoteAssetDigest.sha256Hex(data) == sha256 else {
      throw RemoteAssetError.hashMismatch
    }
    return destination.path
  }

  static func retainAttachments(projectPath: String, nodeID: UUID, names: Set<String>) throws {
    let directory = NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw RemoteAssetError.unsafeFile
    }
    let entries = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [])
    for entry in entries where !names.contains(entry.lastPathComponent) {
      _ = try SafeLocalFile.read(entry, maximumBytes: AttachmentUploadDeclaration.maximumFileBytes)
      try FileManager.default.removeItem(at: entry)
    }
  }
}

private enum SSHRemoteAssetHost {
  private static let commandTimeout: Duration = .seconds(30)

  private struct Document: Decodable {
    var scope: String
    var name: String
    var content: String
  }

  static func templateDocuments(
    projectPath: String, maximumBytes: Int
  ) async throws -> [(origin: TemplateOrigin, fileName: String, content: String)] {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath) else {
      throw RemoteAssetError.unauthorized
    }
    let script = """
      import base64,json,os,stat,sys
      root=sys.argv[1]; limit=int(sys.argv[2]); total=0; out=[]
      for scope,d in (("project",os.path.join(root,".graphcode","templates")),("home",os.path.expanduser("~/.graphcode/templates"))):
       try: names=sorted(os.listdir(d))
       except OSError: continue
       for n in names:
        if not n.endswith(".md") or "/" in n or "\\\\" in n: continue
        p=os.path.join(d,n)
        fd=-1
        try:
         fd=os.open(p,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0))
         s=os.fstat(fd)
         if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_size > limit: continue
         b=os.read(fd,limit+1)
        except OSError: continue
        finally:
         if fd>=0: os.close(fd)
        total += len(b)
        if len(b)>limit or total>limit: raise SystemExit(2)
        out.append({"scope":scope,"name":n,"content":base64.b64encode(b).decode("ascii")})
      print(json.dumps(out,separators=(",",":")))
      """
    let data = try await run(
      location: location, script: script,
      arguments: [location.remotePath, String(maximumBytes)], input: nil,
      maximumOutputBytes: maximumBytes * 2)
    let decoded = try JSONDecoder().decode([Document].self, from: data)
    return try decoded.map { document in
      guard AttachmentUploadDeclaration.isSafeName(document.name),
        let bytes = Data(base64Encoded: document.content),
        bytes.count <= maximumBytes,
        let content = String(data: bytes, encoding: .utf8)
      else { throw RemoteAssetError.unsafeFile }
      let origin: TemplateOrigin =
        document.scope == "project" ? .project(projectPath) : .home
      return (origin, document.name, content)
    }
  }

  static func stageAttachment(
    projectPath: String, locationKind: ProjectLocationKind, nodeID: UUID, name: String, data: Data
  ) async throws -> String {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath) else {
      throw RemoteAssetError.unauthorized
    }
    let identity = RemoteAssetIdentity.project(projectPath, locationKind)
    let script = """
      import os,stat,sys,tempfile
      ident,node,name,size=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4])
      base=os.path.expanduser("~/.graphcode")
      roots=[base,os.path.join(base,"staging"),os.path.join(base,"staging",ident),os.path.join(base,"staging",ident,node)]
      for root in roots:
       if os.path.lexists(root):
        s=os.lstat(root)
        if not stat.S_ISDIR(s.st_mode) or stat.S_ISLNK(s.st_mode): raise SystemExit(5)
       else: os.mkdir(root,mode=0o700)
      root=roots[-1]
      dst=os.path.join(root,name)
      if os.path.lexists(dst): raise SystemExit(3)
      b=sys.stdin.buffer.read(size+1)
      if len(b)!=size: raise SystemExit(4)
      fd,tmp=tempfile.mkstemp(prefix=".upload-",dir=root)
      try:
       n=os.write(fd,b)
       if n!=len(b): raise OSError("short write")
       os.fsync(fd); os.fchmod(fd,0o600); os.close(fd); fd=-1
       os.link(tmp,dst)
       os.unlink(tmp)
      finally:
       if fd>=0: os.close(fd)
       if os.path.exists(tmp): os.unlink(tmp)
      print(dst)
      """
    _ = try await run(
      location: location, script: script,
      arguments: [identity, nodeID.uuidString, name, String(data.count)], input: data,
      maximumOutputBytes: 4096)
    return "~/.graphcode/staging/\(identity)/\(nodeID.uuidString)/\(name)"
  }

  static func discardAttachments(
    projectPath: String, locationKind: ProjectLocationKind, nodeID: UUID
  ) async {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath) else { return }
    let identity = RemoteAssetIdentity.project(projectPath, locationKind)
    let script = """
      import os,shutil,sys
      root=os.path.expanduser(os.path.join("~/.graphcode/staging",sys.argv[1],sys.argv[2]))
      if os.path.isdir(root) and not os.path.islink(root): shutil.rmtree(root)
      """
    _ = try? await run(
      location: location, script: script, arguments: [identity, nodeID.uuidString],
      input: nil, maximumOutputBytes: 1024)
  }

  static func resolveAttachment(
    projectPath: String, locationKind: ProjectLocationKind, nodeID: UUID, name: String, size: Int,
    sha256: String
  ) async throws -> String {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath) else {
      throw RemoteAssetError.unauthorized
    }
    let identity = RemoteAssetIdentity.project(projectPath, locationKind)
    let script = """
      import hashlib,os,stat,sys
      ident,node,name,size,digest=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4]),sys.argv[5]
      root=os.path.expanduser(os.path.join("~/.graphcode/staging",ident,node))
      p=os.path.join(root,name)
      fd=-1
      try:
       rs=os.lstat(root)
       fd=os.open(p,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0))
       s=os.fstat(fd)
       if not stat.S_ISDIR(rs.st_mode) or stat.S_ISLNK(rs.st_mode): raise SystemExit(2)
       if not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_nlink != 1 or s.st_size != size: raise SystemExit(3)
       b=os.read(fd,size+1)
       if len(b)!=size or hashlib.sha256(b).hexdigest()!=digest: raise SystemExit(4)
      except OSError: raise SystemExit(5)
      finally:
       if fd>=0: os.close(fd)
      print(p)
      """
    let data = try await run(
      location: location, script: script,
      arguments: [identity, nodeID.uuidString, name, String(size), sha256], input: nil,
      maximumOutputBytes: 4096)
    guard
      let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty
    else { throw RemoteAssetError.transportFailure }
    return path
  }

  static func retainAttachments(
    projectPath: String, locationKind: ProjectLocationKind, nodeID: UUID, names: Set<String>
  ) async throws {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath) else {
      throw RemoteAssetError.unauthorized
    }
    let identity = RemoteAssetIdentity.project(projectPath, locationKind)
    let encodedNames = try JSONEncoder().encode(Array(names).sorted())
    let script = """
      import json,os,stat,sys
      ident,node=sys.argv[1],sys.argv[2]
      allowed=set(json.load(sys.stdin))
      root=os.path.expanduser(os.path.join("~/.graphcode/staging",ident,node))
      if not os.path.lexists(root): raise SystemExit(0)
      rs=os.lstat(root)
      if not stat.S_ISDIR(rs.st_mode) or stat.S_ISLNK(rs.st_mode): raise SystemExit(2)
      for name in os.listdir(root):
       p=os.path.join(root,name); s=os.lstat(p)
       if name in allowed: continue
       if not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_nlink != 1: raise SystemExit(3)
       os.unlink(p)
      """
    _ = try await run(
      location: location, script: script, arguments: [identity, nodeID.uuidString],
      input: encodedNames, maximumOutputBytes: 1024)
  }

  private static func run(
    location: RemoteProjectLocation,
    script: String,
    arguments: [String],
    input: Data?,
    maximumOutputBytes: Int
  ) async throws -> Data {
    RemoteProjectLocation.prepareControlSocketDirectory()
    let command = (["python3", "-c", script] + arguments)
      .map(RemoteProjectLocation.shellQuoted).joined(separator: " ")
    let invocation = location.sshInvocation(remoteCommand: command)
    guard let executable = invocation.first else { throw RemoteAssetError.transportFailure }
    return try await Task.detached {
      let process = Process()
      let output = Pipe()
      let errors = Pipe()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = Array(invocation.dropFirst())
      process.standardOutput = output
      process.standardError = errors
      let inputPipe = input.map { _ in Pipe() }
      process.standardInput = inputPipe ?? FileHandle.nullDevice
      try process.run()
      let timeoutTask = Task {
        try? await Task.sleep(for: commandTimeout)
        if process.isRunning { process.terminate() }
      }
      defer { timeoutTask.cancel() }
      let outputTask = Task.detached {
        try Self.boundedRead(output.fileHandleForReading, maximumBytes: maximumOutputBytes)
      }
      let errorTask = Task.detached {
        try Self.boundedRead(errors.fileHandleForReading, maximumBytes: 64 * 1024)
      }
      do {
        if let input, let inputPipe {
          try inputPipe.fileHandleForWriting.write(contentsOf: input)
          try inputPipe.fileHandleForWriting.close()
        }
        let data = try await outputTask.value
        _ = try await errorTask.value
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
          throw RemoteAssetError.transportFailure
        }
        return data
      } catch {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        outputTask.cancel()
        errorTask.cancel()
        _ = try? await outputTask.value
        _ = try? await errorTask.value
        throw RemoteAssetError.transportFailure
      }
    }.value
  }

  private static func boundedRead(_ handle: FileHandle, maximumBytes: Int) throws -> Data {
    var data = Data()
    while true {
      let remaining = maximumBytes - data.count
      guard remaining >= 0 else { throw RemoteAssetError.transportFailure }
      let chunk = try handle.read(upToCount: min(64 * 1024, remaining + 1)) ?? Data()
      guard !chunk.isEmpty else { return data }
      data.append(chunk)
      guard data.count <= maximumBytes else { throw RemoteAssetError.transportFailure }
    }
  }
}
