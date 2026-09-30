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
  public var removeAttachment:
    @Sendable (
      _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ name: String
    ) async throws -> Void
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
    removeAttachment:
      @escaping @Sendable (
        _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ name: String
      ) async throws -> Void = { _, _, _, _ in throw RemoteAssetError.transportFailure },
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
    self.removeAttachment = removeAttachment
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
    removeAttachment: { projectPath, metadata, nodeID, name in
      switch metadata.location {
      case .local:
        try LocalRemoteAssetHost.removeAttachment(
          projectPath: projectPath, nodeID: nodeID, name: name)
      case .ssh, .codespace:
        try await SSHRemoteAssetHost.removeAttachment(
          projectPath: projectPath, locationKind: metadata.location, nodeID: nodeID, name: name)
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
  public static let maximumActiveTransfersPerOwner = 32
  public static let maximumActiveTransfersPerProject = 128
  public static let maximumActiveTransfersGlobal = 256
  public static let maximumDeclaredBytesPerOwner = 64 * 1024 * 1024
  public static let maximumDeclaredBytesPerProject = 256 * 1024 * 1024
  public static let maximumDeclaredBytesGlobal = 512 * 1024 * 1024
  public static let maximumBufferedBytesPerOwner = 32 * 1024 * 1024
  public static let maximumBufferedBytesPerProject = 128 * 1024 * 1024
  public static let maximumBufferedBytesGlobal = 256 * 1024 * 1024

  private struct Transfer: Sendable {
    var owner: UUID
    var connectionID: UUID
    var projectPath: String
    var metadata: ProjectMetadata
    var nodeID: UUID
    var declaration: AttachmentUploadDeclaration
    var bytes: Data
    var expiresAt: Date
  }

  private struct Usage: Sendable {
    var count = 0
    var declaredBytes = 0
    var bufferedBytes = 0
  }

  private struct Finalization: Sendable {
    var transfer: Transfer
    var task: Task<String, Error>
    var cancelled: Bool
  }

  private struct PendingDelivery: Sendable {
    var transfer: Transfer
    var attachment: PromptAttachment
  }

  private struct DraftState: Sendable {
    var owner: UUID
    var names: Set<String>
  }

  private struct ReferencePayload: Codable, Equatable, Sendable {
    var version: Int
    var projectIdentity: String
    var nodeID: UUID
    var name: String
    var size: Int
    var sha256: String
    var draftOwner: UUID?
  }

  private struct TemplatePayload: Codable, Equatable, Sendable {
    var version: Int
    var projectIdentity: String
    var templateID: UUID
    var origin: String
    var fileName: String
    var sha256: String
  }

  private struct TemplateCandidate: Sendable {
    var template: PromptTemplate
    var fileName: String
    var originKey: String
    var sha256: String
  }

  private let transport: RemoteAssetHostTransport
  private let authenticationKey: Data?
  private let now: @Sendable () -> Date
  private let attachmentsDirectory: @Sendable (String, UUID) -> URL
  private var transfers: [UUID: Transfer] = [:]
  private var finalizations: [UUID: Finalization] = [:]
  private var pendingDeliveries: [UUID: PendingDelivery] = [:]
  private var cancellationOutcomes: [UUID: Bool] = [:]
  private var cleanupPending: [UUID: Transfer] = [:]
  private var drafts: [String: DraftState] = [:]
  private var ownerUsage: [UUID: Usage] = [:]
  private var projectUsage: [String: Usage] = [:]
  private var globalUsage = Usage()

  public init(
    transport: RemoteAssetHostTransport = .live,
    authenticationKey: Data? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    attachmentsDirectory: @escaping @Sendable (String, UUID) -> URL = {
      NodeMemory.attachmentsDirectory(forProjectPath: $0, nodeID: $1)
    }
  ) {
    self.transport = transport
    self.authenticationKey = authenticationKey ?? Self.loadAuthenticationKey()
    self.now = now
    self.attachmentsDirectory = attachmentsDirectory
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
      let candidates = try await templateCandidates(
        projectPath: projectPath, metadata: metadata, maximumBytes: query.maxBytes)
      let duplicateIDs = Dictionary(grouping: candidates, by: \.template.id)
        .contains { $0.value.count > 1 }
      guard !duplicateIDs else { return .failure(.ambiguousTemplate) }
      var templates: [RemoteTemplateMetadata] = []
      var encodedBytes = 0
      for candidate in candidates {
        let assetID = try makeTemplateAssetID(
          projectPath: projectPath, metadata: metadata, candidate: candidate)
        let value = RemoteTemplateMetadata(
          id: candidate.template.id, name: candidate.template.name,
          fileName: candidate.fileName, origin: candidate.template.origin, assetID: assetID)
        let size = try JSONEncoder().encode(value).count
        guard templates.count < query.maxCount,
          !encodedBytes.addingReportingOverflow(size).overflow,
          encodedBytes + size <= query.maxBytes
        else { break }
        encodedBytes += size
        templates.append(value)
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
      let candidates = try await templateCandidates(
        projectPath: projectPath, metadata: metadata, maximumBytes: query.maxBytes)
      let matches = candidates.filter { $0.template.id == query.templateID }
      guard let assetID = query.assetID else { return .failure(.invalidReference) }
      let payload = try decodeTemplateAssetID(assetID)
      guard payload.projectIdentity == RemoteAssetIdentity.project(projectPath, metadata),
        payload.templateID == query.templateID
      else { return .failure(.invalidReference) }
      guard
        let selected = matches.first(where: {
          $0.originKey == payload.origin && $0.fileName == payload.fileName
            && $0.sha256 == payload.sha256
        })
      else { return .failure(.invalidReference) }
      return .success(
        RemoteTemplateContent(projectPath: projectPath, template: selected.template))
    } catch let error as RemoteAssetError {
      return .failure(error)
    } catch {
      return .failure(.transportFailure)
    }
  }

  public func beginUpload(
    owner: UUID,
    connectionID: UUID? = nil,
    projectPath: String,
    metadata: ProjectMetadata,
    nodeID: UUID,
    declaration: AttachmentUploadDeclaration,
    existingCount: Int
  ) -> Result<AttachmentUploadTicket, RemoteAssetError> {
    expireTransfers()
    guard metadata.capabilities.attachments else { return .failure(.unsupported) }
    do {
      let declaration = try declaration.validated()
      let key = nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID)
      if let draft = drafts[key], draft.owner != owner { return .failure(.unauthorized) }
      let activeCount = allTransfers.filter {
        $0.projectPath == projectPath && $0.metadata.location == metadata.location
          && $0.nodeID == nodeID
      }.count
      guard
        existingCount + activeCount + (drafts[key]?.names.count ?? 0)
          < AttachmentUploadDeclaration.maximumFilesPerNode
      else { return .failure(.tooManyAttachments) }
      guard
        reserve(owner: owner, project: projectKey(projectPath, metadata), size: declaration.size)
      else { return .failure(.resourceExhausted) }
      let id = UUID()
      let expiresAt = now().addingTimeInterval(Self.transferLifetime)
      transfers[id] = Transfer(
        owner: owner, connectionID: connectionID ?? owner, projectPath: projectPath,
        metadata: metadata, nodeID: nodeID,
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

  public func context(
    owner: UUID, connectionID: UUID? = nil, transferID: UUID
  ) -> Result<AttachmentTransferContext, RemoteAssetError> {
    expireTransfers()
    let transfer =
      transfers[transferID] ?? finalizations[transferID]?.transfer
      ?? pendingDeliveries[transferID]?.transfer
    guard let transfer, transfer.owner == owner,
      connectionID.map({ $0 == transfer.connectionID }) ?? true
    else { return .failure(.unknownTransfer) }
    return .success(
      AttachmentTransferContext(
        projectPath: transfer.projectPath, metadata: transfer.metadata, nodeID: transfer.nodeID))
  }

  public func append(
    owner: UUID, connectionID: UUID? = nil, transferID: UUID, offset: Int, data: Data
  ) -> Result<AttachmentUploadProgress, RemoteAssetError> {
    expireTransfers()
    guard var transfer = transfers[transferID], transfer.owner == owner,
      connectionID.map({ $0 == transfer.connectionID }) ?? true
    else {
      return .failure(.unknownTransfer)
    }
    let next = transfer.bytes.count.addingReportingOverflow(data.count)
    guard data.count <= Self.maximumChunkBytes, offset == transfer.bytes.count,
      !next.overflow, next.partialValue <= transfer.declaration.size
    else {
      return .failure(data.count > Self.maximumChunkBytes ? .oversized : .invalidOffset)
    }
    guard
      reserveBuffered(
        owner: owner, project: projectKey(transfer.projectPath, transfer.metadata),
        bytes: data.count)
    else { return .failure(.resourceExhausted) }
    transfer.bytes.append(data)
    transfers[transferID] = transfer
    return .success(
      AttachmentUploadProgress(transferID: transferID, nextOffset: transfer.bytes.count))
  }

  public func finalize(
    owner: UUID, connectionID: UUID? = nil, transferID: UUID
  ) async -> Result<PromptAttachment, RemoteAssetError> {
    expireTransfers()
    guard let transfer = transfers[transferID], transfer.owner == owner,
      connectionID.map({ $0 == transfer.connectionID }) ?? true
    else {
      return .failure(.unknownTransfer)
    }
    transfers.removeValue(forKey: transferID)
    guard transfer.bytes.count == transfer.declaration.size else {
      transfers[transferID] = transfer
      return .failure(.invalidOffset)
    }
    guard Self.sha256Hex(transfer.bytes) == transfer.declaration.sha256.lowercased() else {
      release(transfer)
      return .failure(.hashMismatch)
    }
    let transport = self.transport
    let task = Task {
      try Task.checkCancellation()
      return try await transport.stageAttachment(
        transfer.projectPath, transfer.metadata, transfer.nodeID, transfer.declaration.name,
        transfer.bytes)
    }
    finalizations[transferID] = Finalization(
      transfer: transfer, task: task, cancelled: false)
    let result = await task.result
    guard let finalization = finalizations.removeValue(forKey: transferID) else {
      return .failure(.unknownTransfer)
    }
    release(finalization.transfer)
    if finalization.cancelled || Task.isCancelled {
      var cleaned = true
      if case .success = result {
        cleaned = await removePublished(finalization.transfer)
      }
      if !cleaned { cleanupPending[transferID] = finalization.transfer }
      cancellationOutcomes[transferID] = cleaned
      return .failure(cleaned ? .unknownTransfer : .transportFailure)
    }
    switch result {
    case .failure(let error):
      if error is CancellationError { return .failure(.unknownTransfer) }
      return .failure(.transportFailure)
    case .success:
      do {
        let reference = try makeReference(
          owner: owner, projectPath: transfer.projectPath, metadata: transfer.metadata,
          nodeID: transfer.nodeID, declaration: transfer.declaration)
        let attachment = PromptAttachment(path: reference, name: transfer.declaration.name)
        pendingDeliveries[transferID] = PendingDelivery(
          transfer: transfer, attachment: attachment)
        return .success(attachment)
      } catch {
        _ = await removePublished(transfer)
        return .failure(.transportFailure)
      }
    }
  }

  public func completeDelivery(
    owner: UUID, connectionID: UUID? = nil, deliveryID: UUID, delivered: Bool
  ) async -> Result<Void, RemoteAssetError> {
    guard let pending = pendingDeliveries[deliveryID], pending.transfer.owner == owner,
      connectionID.map({ $0 == pending.transfer.connectionID }) ?? true
    else { return .failure(.unknownTransfer) }
    pendingDeliveries.removeValue(forKey: deliveryID)
    if delivered {
      let key = nodeKey(
        projectPath: pending.transfer.projectPath, metadata: pending.transfer.metadata,
        nodeID: pending.transfer.nodeID)
      var draft = drafts[key] ?? DraftState(owner: owner, names: [])
      guard draft.owner == owner else {
        _ = await removePublished(pending.transfer)
        return .failure(.unauthorized)
      }
      draft.names.insert(pending.transfer.declaration.name)
      drafts[key] = draft
    } else {
      guard await removePublished(pending.transfer) else {
        cleanupPending[deliveryID] = pending.transfer
        return .failure(.transportFailure)
      }
    }
    return .success(())
  }

  public func cancel(
    owner: UUID, connectionID: UUID? = nil, transferID: UUID
  ) async -> Result<Void, RemoteAssetError> {
    if let transfer = transfers[transferID], transfer.owner == owner,
      connectionID.map({ $0 == transfer.connectionID }) ?? true
    {
      transfers.removeValue(forKey: transferID)
      release(transfer)
      return .success(())
    }
    if var finalization = finalizations[transferID], finalization.transfer.owner == owner,
      connectionID.map({ $0 == finalization.transfer.connectionID }) ?? true
    {
      finalization.cancelled = true
      finalizations[transferID] = finalization
      finalization.task.cancel()
      _ = await finalization.task.result
      if let remaining = finalizations.removeValue(forKey: transferID) {
        release(remaining.transfer)
        guard await removePublished(remaining.transfer) else {
          cleanupPending[transferID] = remaining.transfer
          return .failure(.transportFailure)
        }
      } else if cancellationOutcomes.removeValue(forKey: transferID) == false {
        return .failure(.transportFailure)
      }
      cancellationOutcomes.removeValue(forKey: transferID)
      return .success(())
    }
    if let pending = pendingDeliveries[transferID], pending.transfer.owner == owner,
      connectionID.map({ $0 == pending.transfer.connectionID }) ?? true
    {
      pendingDeliveries.removeValue(forKey: transferID)
      guard await removePublished(pending.transfer) else {
        cleanupPending[transferID] = pending.transfer
        return .failure(.transportFailure)
      }
      return .success(())
    }
    if let transfer = cleanupPending[transferID], transfer.owner == owner,
      connectionID.map({ $0 == transfer.connectionID }) ?? true
    {
      guard await removePublished(transfer) else { return .failure(.transportFailure) }
      cleanupPending.removeValue(forKey: transferID)
      cancellationOutcomes.removeValue(forKey: transferID)
      return .success(())
    }
    return .failure(.unknownTransfer)
  }

  public func disconnected(connectionID: UUID, owner: UUID, ownerStillConnected: Bool) async {
    let ids = Set(
      transfers.filter { $0.value.connectionID == connectionID }.map(\.key)
        + finalizations.filter { $0.value.transfer.connectionID == connectionID }.map(\.key)
        + pendingDeliveries.filter { $0.value.transfer.connectionID == connectionID }.map(\.key)
        + cleanupPending.filter { $0.value.connectionID == connectionID }.map(\.key))
    for id in ids {
      _ = await cancel(owner: owner, connectionID: connectionID, transferID: id)
    }
    for id in cleanupPending.filter({ $0.value.connectionID == connectionID }).map(\.key) {
      _ = await cancel(owner: owner, connectionID: connectionID, transferID: id)
    }
    guard !ownerStillConnected else { return }
    let draftKeys = drafts.filter { $0.value.owner == owner }.map(\.key)
    for key in draftKeys {
      guard let draft = drafts.removeValue(forKey: key),
        let context = parseDraftKey(key)
      else { continue }
      _ = draft
      await transport.discardAttachments(
        context.projectPath, context.metadata, context.nodeID)
    }
  }

  public func disconnected(owner: UUID) async {
    await disconnected(connectionID: owner, owner: owner, ownerStillConnected: false)
  }

  public func validateForCreate(
    _ attachments: [PromptAttachment], owner: UUID, projectPath: String,
    metadata: ProjectMetadata, nodeID: UUID, allowsLegacyLocalPaths: Bool
  ) -> Result<Void, RemoteAssetError> {
    guard attachments.count <= AttachmentUploadDeclaration.maximumFilesPerNode else {
      return .failure(.tooManyAttachments)
    }
    let key = nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID)
    guard
      !allTransfers.contains(where: {
        $0.projectPath == projectPath && $0.metadata.location == metadata.location
          && $0.nodeID == nodeID
      })
    else { return .failure(.invalidReference) }
    if let draft = drafts[key], draft.owner != owner { return .failure(.unauthorized) }
    for attachment in attachments {
      if attachment.isOpaqueReference {
        guard let payload = try? decodeReference(attachment.path),
          payload.projectIdentity == RemoteAssetIdentity.project(projectPath, metadata),
          payload.nodeID == nodeID, payload.name == attachment.fileName,
          payload.draftOwner == owner
        else { return .failure(.invalidReference) }
      } else {
        guard allowsLegacyLocalPaths,
          validateLegacyPath(
            attachment, projectPath: projectPath, metadata: metadata, nodeID: nodeID)
        else { return .failure(.invalidReference) }
      }
    }
    return .success(())
  }

  public func resolvedPath(
    for attachment: PromptAttachment, projectPath: String, nodeID: UUID,
    metadata: ProjectMetadata
  ) async -> Result<String, RemoteAssetError> {
    if !attachment.isOpaqueReference {
      guard
        validateLegacyPath(
          attachment, projectPath: projectPath, metadata: metadata, nodeID: nodeID)
      else { return .failure(.invalidReference) }
      return .success(URL(fileURLWithPath: attachment.path).standardizedFileURL.path)
    }
    guard let payload = try? decodeReference(attachment.path),
      payload.projectIdentity == RemoteAssetIdentity.project(projectPath, metadata),
      payload.nodeID == nodeID, payload.name == attachment.fileName
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

  public func commitCreate(
    _ attachments: [PromptAttachment], owner: UUID, projectPath: String,
    metadata: ProjectMetadata, nodeID: UUID
  ) async -> Result<Void, RemoteAssetError> {
    let key = nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID)
    if let draft = drafts[key], draft.owner != owner { return .failure(.unauthorized) }
    let names = Set(attachments.map(\.fileName))
    do {
      try await transport.retainAttachments(projectPath, metadata, nodeID, names)
      drafts.removeValue(forKey: key)
      return .success(())
    } catch let error as RemoteAssetError {
      return .failure(error)
    } catch {
      return .failure(.transportFailure)
    }
  }

  public func discardDraft(
    owner: UUID, projectPath: String, metadata: ProjectMetadata, nodeID: UUID
  ) async -> Result<Void, RemoteAssetError> {
    let key = nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID)
    guard let draft = drafts[key] else { return .success(()) }
    guard draft.owner == owner else { return .failure(.unauthorized) }
    drafts.removeValue(forKey: key)
    await transport.discardAttachments(projectPath, metadata, nodeID)
    return .success(())
  }

  public func discardNode(
    projectPath: String, metadata: ProjectMetadata, nodeID: UUID
  ) async {
    drafts.removeValue(
      forKey: nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID))
    await transport.discardAttachments(projectPath, metadata, nodeID)
  }

  public func resourceUsage() -> RemoteAssetUsageSnapshot {
    RemoteAssetUsageSnapshot(
      activeTransfers: globalUsage.count, declaredBytes: globalUsage.declaredBytes,
      bufferedBytes: globalUsage.bufferedBytes,
      pendingDeliveries: pendingDeliveries.count + cleanupPending.count)
  }

  private var allTransfers: [Transfer] {
    Array(transfers.values) + finalizations.values.map(\.transfer)
      + pendingDeliveries.values.map(\.transfer)
  }

  private func templateCandidates(
    projectPath: String, metadata: ProjectMetadata, maximumBytes: Int
  ) async throws -> [TemplateCandidate] {
    let documents = try await transport.templateDocuments(projectPath, metadata, maximumBytes)
    return documents.compactMap { document in
      guard AttachmentUploadDeclaration.isSafeName(document.fileName),
        document.fileName.hasSuffix(".md"), document.content.utf8.count <= maximumBytes,
        let decoded = TemplateFileCodec.decode(document.content, origin: document.origin)
      else { return nil }
      var template = decoded
      template.fileName = document.fileName
      let originKey: String
      switch document.origin {
      case .home: originKey = "home"
      case .project: originKey = "project"
      }
      return TemplateCandidate(
        template: template, fileName: document.fileName, originKey: originKey,
        sha256: Self.sha256Hex(Data(document.content.utf8)))
    }
  }

  private func expireTransfers() {
    let current = now()
    for (id, transfer) in transfers where transfer.expiresAt <= current {
      transfers.removeValue(forKey: id)
      release(transfer)
    }
  }

  private func reserve(owner: UUID, project: String, size: Int) -> Bool {
    let ownerValue = ownerUsage[owner] ?? Usage()
    let projectValue = projectUsage[project] ?? Usage()
    guard ownerValue.count < Self.maximumActiveTransfersPerOwner,
      projectValue.count < Self.maximumActiveTransfersPerProject,
      globalUsage.count < Self.maximumActiveTransfersGlobal,
      canAdd(ownerValue.declaredBytes, size, limit: Self.maximumDeclaredBytesPerOwner),
      canAdd(projectValue.declaredBytes, size, limit: Self.maximumDeclaredBytesPerProject),
      canAdd(globalUsage.declaredBytes, size, limit: Self.maximumDeclaredBytesGlobal)
    else { return false }
    ownerUsage[owner] = adding(ownerValue, count: 1, declared: size, buffered: 0)
    projectUsage[project] = adding(projectValue, count: 1, declared: size, buffered: 0)
    globalUsage = adding(globalUsage, count: 1, declared: size, buffered: 0)
    return true
  }

  private func reserveBuffered(owner: UUID, project: String, bytes: Int) -> Bool {
    let ownerValue = ownerUsage[owner] ?? Usage()
    let projectValue = projectUsage[project] ?? Usage()
    guard canAdd(ownerValue.bufferedBytes, bytes, limit: Self.maximumBufferedBytesPerOwner),
      canAdd(projectValue.bufferedBytes, bytes, limit: Self.maximumBufferedBytesPerProject),
      canAdd(globalUsage.bufferedBytes, bytes, limit: Self.maximumBufferedBytesGlobal)
    else { return false }
    ownerUsage[owner] = adding(ownerValue, count: 0, declared: 0, buffered: bytes)
    projectUsage[project] = adding(projectValue, count: 0, declared: 0, buffered: bytes)
    globalUsage = adding(globalUsage, count: 0, declared: 0, buffered: bytes)
    return true
  }

  private func release(_ transfer: Transfer) {
    let project = projectKey(transfer.projectPath, transfer.metadata)
    ownerUsage[transfer.owner] = subtracting(
      ownerUsage[transfer.owner] ?? Usage(), count: 1, declared: transfer.declaration.size,
      buffered: transfer.bytes.count)
    projectUsage[project] = subtracting(
      projectUsage[project] ?? Usage(), count: 1, declared: transfer.declaration.size,
      buffered: transfer.bytes.count)
    globalUsage = subtracting(
      globalUsage, count: 1, declared: transfer.declaration.size,
      buffered: transfer.bytes.count)
    if ownerUsage[transfer.owner] == nil || isEmpty(ownerUsage[transfer.owner]!) {
      ownerUsage.removeValue(forKey: transfer.owner)
    }
    if projectUsage[project] == nil || isEmpty(projectUsage[project]!) {
      projectUsage.removeValue(forKey: project)
    }
  }

  private func adding(_ usage: Usage, count: Int, declared: Int, buffered: Int) -> Usage {
    Usage(
      count: usage.count + count, declaredBytes: usage.declaredBytes + declared,
      bufferedBytes: usage.bufferedBytes + buffered)
  }

  private func subtracting(_ usage: Usage, count: Int, declared: Int, buffered: Int) -> Usage {
    Usage(
      count: max(0, usage.count - count),
      declaredBytes: max(0, usage.declaredBytes - declared),
      bufferedBytes: max(0, usage.bufferedBytes - buffered))
  }

  private func isEmpty(_ usage: Usage) -> Bool {
    usage.count == 0 && usage.declaredBytes == 0 && usage.bufferedBytes == 0
  }

  private func canAdd(_ lhs: Int, _ rhs: Int, limit: Int) -> Bool {
    let value = lhs.addingReportingOverflow(rhs)
    return !value.overflow && value.partialValue <= limit
  }

  private func projectKey(_ path: String, _ metadata: ProjectMetadata) -> String {
    RemoteAssetIdentity.project(path, metadata)
  }

  private func nodeKey(projectPath: String, metadata: ProjectMetadata, nodeID: UUID) -> String {
    "\(projectPath)\u{0}\(metadata.location.rawValue)\u{0}\(nodeID.uuidString)"
  }

  private func parseDraftKey(_ key: String) -> AttachmentTransferContext? {
    let parts = key.split(separator: "\u{0}", omittingEmptySubsequences: false)
    guard parts.count == 3, let location = ProjectLocationKind(rawValue: String(parts[1])),
      let nodeID = UUID(uuidString: String(parts[2]))
    else { return nil }
    let metadata: ProjectMetadata
    switch location {
    case .local: metadata = .local
    case .ssh: metadata = .ssh
    case .codespace: metadata = .codespace
    }
    return AttachmentTransferContext(
      projectPath: String(parts[0]), metadata: metadata, nodeID: nodeID)
  }

  private func makeReference(
    owner: UUID, projectPath: String, metadata: ProjectMetadata, nodeID: UUID,
    declaration: AttachmentUploadDeclaration
  ) throws -> String {
    let payload = ReferencePayload(
      version: 1, projectIdentity: RemoteAssetIdentity.project(projectPath, metadata),
      nodeID: nodeID, name: declaration.name, size: declaration.size,
      sha256: declaration.sha256.lowercased(), draftOwner: owner)
    return try authenticatedValue(prefix: PromptAttachment.opaqueReferencePrefix, payload: payload)
  }

  private func decodeReference(_ value: String) throws -> ReferencePayload {
    let decoded: ReferencePayload = try decodeAuthenticatedValue(
      value, prefix: PromptAttachment.opaqueReferencePrefix)
    guard decoded.version == 1, AttachmentUploadDeclaration.isSafeName(decoded.name),
      decoded.size > 0, decoded.size <= AttachmentUploadDeclaration.maximumFileBytes,
      decoded.sha256.count == 64, decoded.sha256.allSatisfy(\.isHexDigit)
    else { throw RemoteAssetError.invalidReference }
    return decoded
  }

  private func makeTemplateAssetID(
    projectPath: String, metadata: ProjectMetadata, candidate: TemplateCandidate
  ) throws -> String {
    try authenticatedValue(
      prefix: "graphcode-template:v1:",
      payload: TemplatePayload(
        version: 1, projectIdentity: RemoteAssetIdentity.project(projectPath, metadata),
        templateID: candidate.template.id, origin: candidate.originKey,
        fileName: candidate.fileName, sha256: candidate.sha256))
  }

  private func decodeTemplateAssetID(_ value: String) throws -> TemplatePayload {
    let decoded: TemplatePayload = try decodeAuthenticatedValue(
      value, prefix: "graphcode-template:v1:")
    guard decoded.version == 1, ["home", "project"].contains(decoded.origin),
      AttachmentUploadDeclaration.isSafeName(decoded.fileName),
      decoded.sha256.count == 64, decoded.sha256.allSatisfy(\.isHexDigit)
    else { throw RemoteAssetError.invalidReference }
    return decoded
  }

  private func authenticatedValue<T: Encodable>(prefix: String, payload: T) throws -> String {
    guard let authenticationKey else { throw RemoteAssetError.transportFailure }
    let data = try JSONEncoder().encode(payload)
    let signature = Self.hmacSHA256(key: authenticationKey, message: data)
    return "\(prefix)\(Self.base64URL(data)).\(Self.base64URL(signature))"
  }

  private func decodeAuthenticatedValue<T: Decodable>(
    _ value: String, prefix: String
  ) throws -> T {
    guard let authenticationKey, value.hasPrefix(prefix) else {
      throw RemoteAssetError.invalidReference
    }
    let parts = value.dropFirst(prefix.count).split(
      separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, let payload = Self.decodeBase64URL(String(parts[0])),
      let signature = Self.decodeBase64URL(String(parts[1])),
      Self.constantTimeEqual(signature, Self.hmacSHA256(key: authenticationKey, message: payload)),
      let decoded = try? JSONDecoder().decode(T.self, from: payload)
    else { throw RemoteAssetError.invalidReference }
    return decoded
  }

  private func validateLegacyPath(
    _ attachment: PromptAttachment, projectPath: String, metadata: ProjectMetadata, nodeID: UUID
  ) -> Bool {
    guard metadata.location == .local,
      AttachmentUploadDeclaration.isSafeName(attachment.fileName)
    else { return false }
    let directory = attachmentsDirectory(projectPath, nodeID).standardizedFileURL
    let candidate = URL(fileURLWithPath: attachment.path).standardizedFileURL
    guard candidate.lastPathComponent == attachment.fileName,
      candidate.deletingLastPathComponent() == directory,
      (try? SafeLocalFile.validateDirectory(directory)) != nil,
      (try? SafeLocalFile.read(
        candidate, maximumBytes: AttachmentUploadDeclaration.maximumFileBytes)) != nil
    else { return false }
    return true
  }

  private func removePublished(_ transfer: Transfer) async -> Bool {
    for attempt in 0..<3 {
      do {
        try await transport.removeAttachment(
          transfer.projectPath, transfer.metadata, transfer.nodeID, transfer.declaration.name)
        return true
      } catch {
        if attempt < 2 { await Task.yield() }
      }
    }
    return false
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
    try SafeLocalFile.validateDirectory(directory)
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

  static func removeAttachment(projectPath: String, nodeID: UUID, name: String) throws {
    let directory = NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
    let destination = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: destination.path) else { return }
    _ = try SafeLocalFile.read(
      destination, maximumBytes: AttachmentUploadDeclaration.maximumFileBytes)
    try FileManager.default.removeItem(at: destination)
    if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  static func resolveAttachment(
    projectPath: String, nodeID: UUID, name: String, size: Int, sha256: String
  ) throws -> String {
    let directory = NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
    let destination = directory.appendingPathComponent(name)
    try SafeLocalFile.validateDirectory(directory)
    let data = try SafeLocalFile.read(destination, maximumBytes: size)
    guard data.count == size, RemoteAssetDigest.sha256Hex(data) == sha256 else {
      throw RemoteAssetError.hashMismatch
    }
    return destination.path
  }

  static func retainAttachments(projectPath: String, nodeID: UUID, names: Set<String>) throws {
    let directory = NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try SafeLocalFile.validateDirectory(directory)
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

  static func removeAttachment(
    projectPath: String, locationKind: ProjectLocationKind, nodeID: UUID, name: String
  ) async throws {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath) else {
      throw RemoteAssetError.unauthorized
    }
    let identity = RemoteAssetIdentity.project(projectPath, locationKind)
    let script = """
      import os,stat,sys
      root=os.path.expanduser(os.path.join("~/.graphcode/staging",sys.argv[1],sys.argv[2]))
      p=os.path.join(root,sys.argv[3])
      if os.path.lexists(p):
       s=os.lstat(p)
       if not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_nlink != 1: raise SystemExit(2)
       os.unlink(p)
      try:
       if not os.listdir(root): os.rmdir(root)
      except OSError: pass
      """
    _ = try await run(
      location: location, script: script, arguments: [identity, nodeID.uuidString, name],
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
      return try await withTaskCancellationHandler {
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
      } onCancel: {
        if process.isRunning { process.terminate() }
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
