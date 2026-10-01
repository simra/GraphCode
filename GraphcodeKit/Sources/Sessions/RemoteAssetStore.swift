import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct RemoteAssetRetentionDescriptor: Codable, Equatable, Hashable, Sendable {
  public var name: String
  public var size: Int
  public var sha256: String

  public init(name: String, size: Int, sha256: String) {
    self.name = name
    self.size = size
    self.sha256 = sha256.lowercased()
  }
}

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
  public var acquireAttachmentLease:
    @Sendable (
      _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ leaseID: UUID,
      _ descriptors: [RemoteAssetRetentionDescriptor]
    ) async throws -> Void
  public var verifyAttachmentLease:
    @Sendable (
      _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ leaseID: UUID,
      _ descriptors: [RemoteAssetRetentionDescriptor]
    ) async throws -> Void
  public var commitAttachmentLease:
    @Sendable (
      _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ leaseID: UUID,
      _ descriptors: [RemoteAssetRetentionDescriptor]
    ) async throws -> Void
  public var rollbackAttachmentLease:
    @Sendable (
      _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ leaseID: UUID,
      _ descriptors: [RemoteAssetRetentionDescriptor]
    ) async throws -> Void
  public var resolveLeasedAttachment:
    @Sendable (
      _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ leaseID: UUID,
      _ descriptor: RemoteAssetRetentionDescriptor
    ) async throws -> String

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
      ) async throws -> Void,
    acquireAttachmentLease:
      (
        @Sendable (
          _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ leaseID: UUID,
          _ descriptors: [RemoteAssetRetentionDescriptor]
        ) async throws -> Void
      )? = nil,
    verifyAttachmentLease:
      (
        @Sendable (
          _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ leaseID: UUID,
          _ descriptors: [RemoteAssetRetentionDescriptor]
        ) async throws -> Void
      )? = nil,
    commitAttachmentLease:
      (
        @Sendable (
          _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ leaseID: UUID,
          _ descriptors: [RemoteAssetRetentionDescriptor]
        ) async throws -> Void
      )? = nil,
    rollbackAttachmentLease:
      (
        @Sendable (
          _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ leaseID: UUID,
          _ descriptors: [RemoteAssetRetentionDescriptor]
        ) async throws -> Void
      )? = nil,
    resolveLeasedAttachment:
      (
        @Sendable (
          _ projectPath: String, _ metadata: ProjectMetadata, _ nodeID: UUID, _ leaseID: UUID,
          _ descriptor: RemoteAssetRetentionDescriptor
        ) async throws -> String
      )? = nil
  ) {
    self.templateDocuments = templateDocuments
    self.stageAttachment = stageAttachment
    self.discardAttachments = discardAttachments
    self.removeAttachment = removeAttachment
    self.resolveAttachment = resolveAttachment
    self.retainAttachments = retainAttachments
    self.acquireAttachmentLease =
      acquireAttachmentLease
      ?? { projectPath, metadata, nodeID, _, descriptors in
        try await retainAttachments(projectPath, metadata, nodeID, Set(descriptors.map(\.name)))
      }
    self.verifyAttachmentLease =
      verifyAttachmentLease
      ?? { projectPath, metadata, nodeID, _, descriptors in
        for descriptor in descriptors {
          _ = try await resolveAttachment(
            projectPath, metadata, nodeID, descriptor.name, descriptor.size, descriptor.sha256)
        }
      }
    self.commitAttachmentLease =
      commitAttachmentLease
      ?? { projectPath, metadata, nodeID, _, descriptors in
        try await retainAttachments(projectPath, metadata, nodeID, Set(descriptors.map(\.name)))
      }
    self.rollbackAttachmentLease =
      rollbackAttachmentLease
      ?? { projectPath, metadata, nodeID, _, descriptors in
        for descriptor in descriptors {
          try await removeAttachment(projectPath, metadata, nodeID, descriptor.name)
        }
      }
    self.resolveLeasedAttachment =
      resolveLeasedAttachment
      ?? { projectPath, metadata, nodeID, _, descriptor in
        try await resolveAttachment(
          projectPath, metadata, nodeID, descriptor.name, descriptor.size, descriptor.sha256)
      }
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
    },
    acquireAttachmentLease: { projectPath, metadata, nodeID, leaseID, descriptors in
      switch metadata.location {
      case .local:
        try LocalRemoteAssetHost.acquireAttachmentLease(
          projectPath: projectPath, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
      case .ssh, .codespace:
        try await SSHRemoteAssetHost.acquireAttachmentLease(
          projectPath: projectPath, locationKind: metadata.location, nodeID: nodeID,
          leaseID: leaseID, descriptors: descriptors)
      }
    },
    verifyAttachmentLease: { projectPath, metadata, nodeID, leaseID, descriptors in
      switch metadata.location {
      case .local:
        try LocalRemoteAssetHost.verifyAttachmentLease(
          projectPath: projectPath, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
      case .ssh, .codespace:
        try await SSHRemoteAssetHost.verifyAttachmentLease(
          projectPath: projectPath, locationKind: metadata.location, nodeID: nodeID,
          leaseID: leaseID, descriptors: descriptors)
      }
    },
    commitAttachmentLease: { projectPath, metadata, nodeID, leaseID, descriptors in
      switch metadata.location {
      case .local:
        try LocalRemoteAssetHost.commitAttachmentLease(
          projectPath: projectPath, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
      case .ssh, .codespace:
        try await SSHRemoteAssetHost.commitAttachmentLease(
          projectPath: projectPath, locationKind: metadata.location, nodeID: nodeID,
          leaseID: leaseID, descriptors: descriptors)
      }
    },
    rollbackAttachmentLease: { projectPath, metadata, nodeID, leaseID, descriptors in
      switch metadata.location {
      case .local:
        try LocalRemoteAssetHost.rollbackAttachmentLease(
          projectPath: projectPath, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
      case .ssh, .codespace:
        try await SSHRemoteAssetHost.rollbackAttachmentLease(
          projectPath: projectPath, locationKind: metadata.location, nodeID: nodeID,
          leaseID: leaseID, descriptors: descriptors)
      }
    },
    resolveLeasedAttachment: { projectPath, metadata, nodeID, leaseID, descriptor in
      switch metadata.location {
      case .local:
        return try LocalRemoteAssetHost.resolveLeasedAttachment(
          projectPath: projectPath, nodeID: nodeID, leaseID: leaseID, descriptor: descriptor)
      case .ssh, .codespace:
        return try await SSHRemoteAssetHost.resolveLeasedAttachment(
          projectPath: projectPath, locationKind: metadata.location, nodeID: nodeID,
          leaseID: leaseID, descriptor: descriptor)
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
  public static let finalizedDraftLifetime: TimeInterval = 15 * 60
  public static let maximumFinalizedDraftsPerOwner = 64
  public static let maximumFinalizedDraftsPerProject = 256
  public static let maximumFinalizedDraftsGlobal = 512
  public static let maximumFinalizedAttachmentsPerOwner = 128
  public static let maximumFinalizedAttachmentsPerProject = 512
  public static let maximumFinalizedAttachmentsGlobal = 1024
  public static let maximumFinalizedBytesPerOwner = 64 * 1024 * 1024
  public static let maximumFinalizedBytesPerProject = 256 * 1024 * 1024
  public static let maximumFinalizedBytesGlobal = 512 * 1024 * 1024
  public static let maximumCleanupRecords = 2_048
  public static let maximumCleanupBytes = 1024 * 1024 * 1024
  public static let cleanupLifetime: TimeInterval = 7 * 24 * 60 * 60
  public static let maximumCleanupAttempts = 8

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

  private struct DraftState: Codable, Sendable {
    var owner: UUID
    var projectPath: String
    var projectIdentity: String
    var metadata: ProjectMetadata
    var nodeID: UUID
    var files: [String: RemoteAssetRetentionDescriptor]
    var provisional: Set<String>
    var createdAt: Date
    var expiresAt: Date
    var leaseID: UUID?

    private enum CodingKeys: String, CodingKey {
      case owner, projectIdentity, metadata, nodeID, files, provisional, createdAt, expiresAt,
        leaseID
    }

    init(
      owner: UUID, projectPath: String, projectIdentity: String, metadata: ProjectMetadata,
      nodeID: UUID, files: [String: RemoteAssetRetentionDescriptor], provisional: Set<String>,
      createdAt: Date, expiresAt: Date, leaseID: UUID?
    ) {
      self.owner = owner
      self.projectPath = projectPath
      self.projectIdentity = projectIdentity
      self.metadata = metadata
      self.nodeID = nodeID
      self.files = files
      self.provisional = provisional
      self.createdAt = createdAt
      self.expiresAt = expiresAt
      self.leaseID = leaseID
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      owner = try values.decode(UUID.self, forKey: .owner)
      projectPath = ""
      projectIdentity = try values.decode(String.self, forKey: .projectIdentity)
      metadata = try values.decode(ProjectMetadata.self, forKey: .metadata)
      nodeID = try values.decode(UUID.self, forKey: .nodeID)
      files = try values.decode([String: RemoteAssetRetentionDescriptor].self, forKey: .files)
      provisional = try values.decode(Set<String>.self, forKey: .provisional)
      createdAt = try values.decode(Date.self, forKey: .createdAt)
      expiresAt = try values.decode(Date.self, forKey: .expiresAt)
      leaseID = try values.decodeIfPresent(UUID.self, forKey: .leaseID)
    }
  }

  private struct DraftUsage: Sendable {
    var drafts = 0
    var attachments = 0
    var bytes = 0
  }

  private struct DraftLease: Codable, Sendable {
    var key: String
    var owner: UUID
    var projectPath: String
    var projectIdentity: String
    var metadata: ProjectMetadata
    var nodeID: UUID
    var descriptors: [RemoteAssetRetentionDescriptor]
    var createdAt: Date
    var expiresAt: Date
    var acquired: Bool
    var committed: Bool

    private enum CodingKeys: String, CodingKey {
      case key, owner, projectIdentity, metadata, nodeID, descriptors, createdAt, expiresAt
      case acquired, committed
    }

    init(
      key: String, owner: UUID, projectPath: String, projectIdentity: String,
      metadata: ProjectMetadata, nodeID: UUID,
      descriptors: [RemoteAssetRetentionDescriptor], createdAt: Date, expiresAt: Date,
      acquired: Bool, committed: Bool
    ) {
      self.key = key
      self.owner = owner
      self.projectPath = projectPath
      self.projectIdentity = projectIdentity
      self.metadata = metadata
      self.nodeID = nodeID
      self.descriptors = descriptors
      self.createdAt = createdAt
      self.expiresAt = expiresAt
      self.acquired = acquired
      self.committed = committed
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      key = try values.decode(String.self, forKey: .key)
      owner = try values.decode(UUID.self, forKey: .owner)
      projectPath = ""
      projectIdentity = try values.decode(String.self, forKey: .projectIdentity)
      metadata = try values.decode(ProjectMetadata.self, forKey: .metadata)
      nodeID = try values.decode(UUID.self, forKey: .nodeID)
      descriptors = try values.decode([RemoteAssetRetentionDescriptor].self, forKey: .descriptors)
      createdAt = try values.decode(Date.self, forKey: .createdAt)
      expiresAt = try values.decode(Date.self, forKey: .expiresAt)
      acquired = try values.decode(Bool.self, forKey: .acquired)
      committed = try values.decode(Bool.self, forKey: .committed)
    }
  }

  private enum CleanupTarget: String, Codable, Sendable {
    case staged
    case lease
  }

  private enum CleanupStatus: String, Codable, Sendable {
    case pending
    case quarantined
  }

  private struct CleanupRecord: Codable, Sendable {
    var key: String
    var context: AttachmentTransferContext
    var projectIdentity: String
    var descriptor: RemoteAssetRetentionDescriptor
    var leaseID: UUID?
    var target: CleanupTarget
    var attempts: Int
    var nextAttemptAt: Date
    var deadline: Date
    var status: CleanupStatus
    var lastError: String?

    private enum CodingKeys: String, CodingKey {
      case key, projectIdentity, metadata, nodeID, descriptor, leaseID, target, attempts
      case nextAttemptAt, deadline, status, lastError
    }

    init(
      key: String, context: AttachmentTransferContext, projectIdentity: String,
      descriptor: RemoteAssetRetentionDescriptor, leaseID: UUID?, target: CleanupTarget,
      attempts: Int, nextAttemptAt: Date, deadline: Date, status: CleanupStatus,
      lastError: String?
    ) {
      self.key = key
      self.context = context
      self.projectIdentity = projectIdentity
      self.descriptor = descriptor
      self.leaseID = leaseID
      self.target = target
      self.attempts = attempts
      self.nextAttemptAt = nextAttemptAt
      self.deadline = deadline
      self.status = status
      self.lastError = lastError
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      key = try values.decode(String.self, forKey: .key)
      projectIdentity = try values.decode(String.self, forKey: .projectIdentity)
      let metadata = try values.decode(ProjectMetadata.self, forKey: .metadata)
      let nodeID = try values.decode(UUID.self, forKey: .nodeID)
      context = AttachmentTransferContext(projectPath: "", metadata: metadata, nodeID: nodeID)
      descriptor = try values.decode(RemoteAssetRetentionDescriptor.self, forKey: .descriptor)
      leaseID = try values.decodeIfPresent(UUID.self, forKey: .leaseID)
      target = try values.decode(CleanupTarget.self, forKey: .target)
      attempts = try values.decode(Int.self, forKey: .attempts)
      nextAttemptAt = try values.decode(Date.self, forKey: .nextAttemptAt)
      deadline = try values.decode(Date.self, forKey: .deadline)
      status = try values.decode(CleanupStatus.self, forKey: .status)
      lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
    }

    func encode(to encoder: Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(key, forKey: .key)
      try values.encode(projectIdentity, forKey: .projectIdentity)
      try values.encode(context.metadata, forKey: .metadata)
      try values.encode(context.nodeID, forKey: .nodeID)
      try values.encode(descriptor, forKey: .descriptor)
      try values.encodeIfPresent(leaseID, forKey: .leaseID)
      try values.encode(target, forKey: .target)
      try values.encode(attempts, forKey: .attempts)
      try values.encode(nextAttemptAt, forKey: .nextAttemptAt)
      try values.encode(deadline, forKey: .deadline)
      try values.encode(status, forKey: .status)
      try values.encodeIfPresent(lastError, forKey: .lastError)
    }
  }

  private struct DurableCatalog: Codable, Sendable {
    var version: Int
    var drafts: [String: DraftState]
    var leases: [UUID: DraftLease]
    var cleanup: [String: CleanupRecord]
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
  private let draftLifetime: TimeInterval
  private let catalogURL: URL?
  private let attachmentsDirectory: @Sendable (String, UUID) -> URL
  private var transfers: [UUID: Transfer] = [:]
  private var finalizations: [UUID: Finalization] = [:]
  private var pendingDeliveries: [UUID: PendingDelivery] = [:]
  private var cancellationOutcomes: [UUID: Bool] = [:]
  private var drafts: [String: DraftState] = [:]
  private var draftLeases: [UUID: DraftLease] = [:]
  private var cleanupQueue: [String: CleanupRecord] = [:]
  private var ownerDraftUsage: [UUID: DraftUsage] = [:]
  private var projectDraftUsage: [String: DraftUsage] = [:]
  private var globalDraftUsage = DraftUsage()
  private var draftExpiryTask: Task<Void, Never>?
  private var ownerUsage: [UUID: Usage] = [:]
  private var projectUsage: [String: Usage] = [:]
  private var globalUsage = Usage()

  public init(
    transport: RemoteAssetHostTransport = .live,
    authenticationKey: Data? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    finalizedDraftLifetime: TimeInterval = RemoteAssetStore.finalizedDraftLifetime,
    catalogURL: URL? = nil,
    attachmentsDirectory: @escaping @Sendable (String, UUID) -> URL = {
      NodeMemory.attachmentsDirectory(forProjectPath: $0, nodeID: $1)
    }
  ) {
    self.transport = transport
    self.authenticationKey = authenticationKey ?? Self.loadAuthenticationKey()
    self.now = now
    draftLifetime = max(0, finalizedDraftLifetime)
    self.catalogURL = catalogURL
    self.attachmentsDirectory = attachmentsDirectory
    let restored = Self.loadCatalog(from: catalogURL)
    drafts = restored.drafts
    draftLeases = restored.leases
    cleanupQueue = restored.cleanup
    for key in drafts.keys where drafts[key]?.provisional.isEmpty == false {
      drafts[key]?.provisional.removeAll()
    }
    for draft in drafts.values {
      let bytes = draft.files.values.reduce(0) { $0 + $1.size }
      let usage = DraftUsage(drafts: 1, attachments: draft.files.count, bytes: bytes)
      let ownerValue = ownerDraftUsage[draft.owner] ?? DraftUsage()
      ownerDraftUsage[draft.owner] = DraftUsage(
        drafts: ownerValue.drafts + usage.drafts,
        attachments: ownerValue.attachments + usage.attachments,
        bytes: ownerValue.bytes + usage.bytes)
      let projectValue = projectDraftUsage[draft.projectIdentity] ?? DraftUsage()
      projectDraftUsage[draft.projectIdentity] = DraftUsage(
        drafts: projectValue.drafts + usage.drafts,
        attachments: projectValue.attachments + usage.attachments,
        bytes: projectValue.bytes + usage.bytes)
      globalDraftUsage = DraftUsage(
        drafts: globalDraftUsage.drafts + usage.drafts,
        attachments: globalDraftUsage.attachments + usage.attachments,
        bytes: globalDraftUsage.bytes + usage.bytes)
    }
    Task { [weak self] in await self?.maintainFinalizedDrafts() }
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
  ) async -> Result<AttachmentUploadTicket, RemoteAssetError> {
    await maintainFinalizedDrafts()
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
        existingCount + activeCount + (drafts[key]?.files.count ?? 0)
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
    await maintainFinalizedDrafts()
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
    guard
      cleanupCapacityAvailable(
        addingCount: 1, addingBytes: transfer.declaration.size)
    else {
      release(transfer)
      return .failure(.resourceExhausted)
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
      if !cleaned { enqueueCleanup(for: finalization.transfer, target: .staged) }
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
        let key = nodeKey(
          projectPath: transfer.projectPath, metadata: transfer.metadata, nodeID: transfer.nodeID)
        let createdAt = now()
        let originalDraft = drafts[key]
        var draft =
          originalDraft
          ?? DraftState(
            owner: owner, projectPath: transfer.projectPath,
            projectIdentity: RemoteAssetIdentity.project(
              transfer.projectPath, transfer.metadata),
            metadata: transfer.metadata,
            nodeID: transfer.nodeID, files: [:], provisional: [], createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(draftLifetime), leaseID: nil)
        guard draft.owner == owner, draft.leaseID == nil,
          draft.files[transfer.declaration.name] == nil
        else {
          if !(await removePublished(transfer)) {
            enqueueCleanup(for: transfer, target: .staged)
          }
          return .failure(.invalidReference)
        }
        let project = projectKey(transfer.projectPath, transfer.metadata)
        guard
          reserveFinalizedDraft(
            owner: owner, project: project, createsDraft: drafts[key] == nil,
            bytes: transfer.declaration.size)
        else {
          if !(await removePublished(transfer)) {
            enqueueCleanup(for: transfer, target: .staged)
          }
          return .failure(.resourceExhausted)
        }
        let descriptor = retentionDescriptor(for: transfer.declaration)
        draft.files[descriptor.name] = descriptor
        draft.provisional.insert(descriptor.name)
        drafts[key] = draft
        guard persistCatalog() else {
          drafts[key] = originalDraft
          releaseFinalizedFile(
            owner: owner, project: project, size: descriptor.size,
            removesDraft: originalDraft == nil)
          if !(await removePublished(transfer)) {
            enqueueCleanup(for: transfer, target: .staged)
          }
          return .failure(.transportFailure)
        }
        pendingDeliveries[transferID] = PendingDelivery(
          transfer: transfer, attachment: attachment)
        scheduleDraftExpiry()
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
    await maintainFinalizedDrafts()
    guard let pending = pendingDeliveries[deliveryID], pending.transfer.owner == owner,
      connectionID.map({ $0 == pending.transfer.connectionID }) ?? true
    else { return .failure(.unknownTransfer) }
    pendingDeliveries.removeValue(forKey: deliveryID)
    let key = nodeKey(
      projectPath: pending.transfer.projectPath, metadata: pending.transfer.metadata,
      nodeID: pending.transfer.nodeID)
    guard var draft = drafts[key],
      let descriptor = draft.files[pending.transfer.declaration.name],
      draft.provisional.contains(descriptor.name)
    else { return .failure(.unknownTransfer) }
    if delivered {
      draft.provisional.remove(descriptor.name)
      drafts[key] = draft
      guard persistCatalog() else { return .failure(.transportFailure) }
      scheduleDraftExpiry()
    } else {
      draft.files.removeValue(forKey: descriptor.name)
      draft.provisional.remove(descriptor.name)
      let removesDraft = draft.files.isEmpty
      if removesDraft {
        drafts.removeValue(forKey: key)
      } else {
        drafts[key] = draft
      }
      releaseFinalizedFile(
        owner: owner, project: projectKey(pending.transfer.projectPath, pending.transfer.metadata),
        size: descriptor.size, removesDraft: removesDraft)
      let removed = await removePublished(pending.transfer)
      if !removed {
        enqueueCleanup(for: pending.transfer, target: .staged)
      }
      guard persistCatalog() else { return .failure(.transportFailure) }
      if !removed { return .failure(.transportFailure) }
    }
    return .success(())
  }

  public func cancel(
    owner: UUID, connectionID: UUID? = nil, transferID: UUID
  ) async -> Result<Void, RemoteAssetError> {
    await maintainFinalizedDrafts()
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
        if !(await removePublished(remaining.transfer)) {
          enqueueCleanup(for: remaining.transfer, target: .staged)
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
      _ = await completeDelivery(
        owner: owner, connectionID: connectionID, deliveryID: transferID, delivered: false)
      return .success(())
    }
    return .failure(.unknownTransfer)
  }

  public func disconnected(connectionID: UUID, owner: UUID, ownerStillConnected: Bool) async {
    await maintainFinalizedDrafts()
    let ids = Set(
      transfers.filter { $0.value.connectionID == connectionID }.map(\.key)
        + finalizations.filter { $0.value.transfer.connectionID == connectionID }.map(\.key)
        + pendingDeliveries.filter { $0.value.transfer.connectionID == connectionID }.map(\.key))
    for id in ids {
      _ = await cancel(owner: owner, connectionID: connectionID, transferID: id)
    }
    guard !ownerStillConnected else { return }
    let draftKeys = drafts.filter { $0.value.owner == owner && $0.value.leaseID == nil }.map(\.key)
    for key in draftKeys {
      _ = await abandonDraft(key: key)
    }
  }

  public func disconnected(owner: UUID) async {
    await disconnected(connectionID: owner, owner: owner, ownerStillConnected: false)
  }

  public func validateForCreate(
    _ attachments: [PromptAttachment], owner: UUID, projectPath: String,
    metadata: ProjectMetadata, nodeID: UUID, allowsLegacyLocalPaths: Bool
  ) async -> Result<Void, RemoteAssetError> {
    await maintainFinalizedDrafts()
    return validateCreateReferences(
      attachments, owner: owner, projectPath: projectPath, metadata: metadata, nodeID: nodeID,
      allowsLegacyLocalPaths: allowsLegacyLocalPaths)
  }

  private func validateCreateReferences(
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
    if drafts[key]?.leaseID != nil { return .failure(.invalidReference) }
    for attachment in attachments {
      if attachment.isOpaqueReference {
        guard let payload = try? decodeReference(attachment.path),
          payload.projectIdentity == RemoteAssetIdentity.project(projectPath, metadata),
          payload.nodeID == nodeID, payload.name == attachment.fileName,
          payload.draftOwner == owner,
          drafts[key]?.files[payload.name]?.size == payload.size,
          drafts[key]?.files[payload.name]?.sha256 == payload.sha256
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
      if let active = draftLeases.first(where: {
        $0.value.projectPath == projectPath
          && $0.value.metadata.location == metadata.location
          && $0.value.nodeID == nodeID
          && $0.value.descriptors.contains(where: { $0.name == payload.name })
      }), let descriptor = active.value.descriptors.first(where: { $0.name == payload.name }) {
        return .success(
          try await transport.resolveLeasedAttachment(
            projectPath, metadata, nodeID, active.key, descriptor))
      }
      return .success(
        try await transport.resolveAttachment(
          projectPath, metadata, nodeID, payload.name, payload.size, payload.sha256))
    } catch let error as RemoteAssetError {
      return .failure(error)
    } catch {
      return .failure(.transportFailure)
    }
  }

  public func prepareCreate(
    _ attachments: [PromptAttachment], owner: UUID, projectPath: String,
    metadata: ProjectMetadata, nodeID: UUID, allowsLegacyLocalPaths: Bool
  ) async -> Result<UUID?, RemoteAssetError> {
    await maintainFinalizedDrafts()
    switch validateCreateReferences(
      attachments, owner: owner, projectPath: projectPath, metadata: metadata, nodeID: nodeID,
      allowsLegacyLocalPaths: allowsLegacyLocalPaths)
    {
    case .failure(let error):
      return .failure(error)
    case .success:
      break
    }
    let key = nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID)
    if attachments.isEmpty { return .success(nil) }
    var descriptors: [RemoteAssetRetentionDescriptor] = []
    var legacyBytes = 0
    var legacyCount = 0
    for attachment in attachments {
      if attachment.isOpaqueReference {
        guard let descriptor = drafts[key]?.files[attachment.fileName] else {
          return .failure(.invalidReference)
        }
        descriptors.append(descriptor)
      } else {
        guard
          let descriptor = legacyRetentionDescriptor(
            attachment, projectPath: projectPath, nodeID: nodeID)
        else { return .failure(.invalidReference) }
        descriptors.append(descriptor)
        guard canAdd(legacyBytes, descriptor.size, limit: Self.maximumCleanupBytes) else {
          return .failure(.resourceExhausted)
        }
        legacyBytes += descriptor.size
        legacyCount += 1
      }
    }
    guard cleanupCapacityAvailable(addingCount: legacyCount, addingBytes: legacyBytes) else {
      return .failure(.resourceExhausted)
    }
    var draft = drafts[key]
    if let existing = draft {
      guard existing.owner == owner, existing.leaseID == nil else {
        return .failure(.unauthorized)
      }
    }
    let leaseID = UUID()
    draft?.leaseID = leaseID
    if let draft { drafts[key] = draft }
    let leaseCreatedAt = now()
    draftLeases[leaseID] = DraftLease(
      key: key, owner: owner, projectPath: projectPath,
      projectIdentity: RemoteAssetIdentity.project(projectPath, metadata),
      metadata: metadata, nodeID: nodeID,
      descriptors: descriptors, createdAt: leaseCreatedAt,
      expiresAt: draft?.expiresAt
        ?? leaseCreatedAt.addingTimeInterval(draftLifetime),
      acquired: false, committed: false)
    guard persistCatalog() else {
      draftLeases.removeValue(forKey: leaseID)
      if var restored = drafts[key] {
        restored.leaseID = nil
        drafts[key] = restored
      }
      return .failure(.transportFailure)
    }
    do {
      try await transport.acquireAttachmentLease(
        projectPath, metadata, nodeID, leaseID, descriptors)
      draftLeases[leaseID]?.acquired = true
      guard persistCatalog() else { throw RemoteAssetError.transportFailure }
      try await transport.verifyAttachmentLease(
        projectPath, metadata, nodeID, leaseID, descriptors)
      draftLeases[leaseID]?.committed = true
      guard persistCatalog() else { throw RemoteAssetError.transportFailure }
      return .success(leaseID)
    } catch let error as RemoteAssetError {
      _ = await rollbackCreate(leaseID: leaseID)
      return .failure(error)
    } catch {
      _ = await rollbackCreate(leaseID: leaseID)
      return .failure(.transportFailure)
    }
  }

  public func finalizeCreate(
    leaseID: UUID, retainedNames: Set<String>
  ) async -> Result<Bool, RemoteAssetError> {
    guard let lease = draftLeases[leaseID], lease.committed else {
      return .failure(.invalidReference)
    }
    do {
      try await transport.verifyAttachmentLease(
        lease.projectPath, lease.metadata, lease.nodeID, leaseID, lease.descriptors)
      try await transport.commitAttachmentLease(
        lease.projectPath, lease.metadata, lease.nodeID, leaseID, lease.descriptors)
      try await transport.verifyAttachmentLease(
        lease.projectPath, lease.metadata, lease.nodeID, leaseID, lease.descriptors)
    } catch let error as RemoteAssetError {
      return .failure(error)
    } catch {
      return .failure(.transportFailure)
    }
    draftLeases.removeValue(forKey: leaseID)
    var deferred = false
    if let draft = drafts.removeValue(forKey: lease.key) {
      releaseFinalizedDraft(
        draft, project: projectKey(lease.projectPath, lease.metadata))
      let unselected = Set(draft.files.keys).subtracting(retainedNames)
      deferred =
        !(await removeDraftFiles(
          owner: draft.owner,
          context: AttachmentTransferContext(
            projectPath: lease.projectPath, metadata: lease.metadata, nodeID: lease.nodeID),
          files: Set(unselected.compactMap { draft.files[$0] })))
    }
    guard persistCatalog() else { return .failure(.transportFailure) }
    scheduleDraftExpiry()
    return .success(deferred)
  }

  public func verifyCreateLease(leaseID: UUID) async -> Result<Void, RemoteAssetError> {
    guard let lease = draftLeases[leaseID], lease.committed else {
      return .failure(.invalidReference)
    }

    do {
      try await transport.verifyAttachmentLease(
        lease.projectPath, lease.metadata, lease.nodeID, leaseID, lease.descriptors)
      return .success(())
    } catch let error as RemoteAssetError {
      return .failure(error)
    } catch {
      return .failure(.transportFailure)
    }
  }

  public func securedAttachments(
    leaseID: UUID, attachments: [PromptAttachment]
  ) -> Result<[PromptAttachment], RemoteAssetError> {
    guard let lease = draftLeases[leaseID], lease.committed,
      attachments.count == lease.descriptors.count
    else { return .failure(.invalidReference) }
    do {
      return .success(
        try zip(attachments, lease.descriptors).map { attachment, descriptor in
          if attachment.isOpaqueReference { return attachment }
          let payload = ReferencePayload(
            version: 1, projectIdentity: lease.projectIdentity, nodeID: lease.nodeID,
            name: descriptor.name, size: descriptor.size, sha256: descriptor.sha256,
            draftOwner: lease.owner)
          return PromptAttachment(
            path: try authenticatedValue(
              prefix: PromptAttachment.opaqueReferencePrefix, payload: payload),
            name: descriptor.name)
        })
    } catch {
      return .failure(.transportFailure)
    }
  }

  public func commitCreate(
    _ attachments: [PromptAttachment], owner: UUID, projectPath: String,
    metadata: ProjectMetadata, nodeID: UUID
  ) async -> Result<Void, RemoteAssetError> {
    switch await prepareCreate(
      attachments, owner: owner, projectPath: projectPath, metadata: metadata, nodeID: nodeID,
      allowsLegacyLocalPaths: metadata.location == .local)
    {
    case .failure(let error):
      return .failure(error)
    case .success(nil):
      return .success(())
    case .success(let leaseID?):
      switch await finalizeCreate(
        leaseID: leaseID, retainedNames: Set(attachments.map(\.fileName)))
      {
      case .success:
        return .success(())
      case .failure(let error):
        return .failure(error)
      }
    }
  }

  public func rollbackCreate(leaseID: UUID) async -> Result<Void, RemoteAssetError> {
    guard let lease = draftLeases.removeValue(forKey: leaseID) else { return .success(()) }
    var leaseCleanupPending = false
    do {
      try await transport.rollbackAttachmentLease(
        lease.projectPath, lease.metadata, lease.nodeID, leaseID, lease.descriptors)
    } catch {
      leaseCleanupPending = true
      for descriptor in lease.descriptors {
        enqueueCleanup(
          context: AttachmentTransferContext(
            projectPath: lease.projectPath, metadata: lease.metadata, nodeID: lease.nodeID),
          descriptor: descriptor, leaseID: leaseID, target: .lease)
      }
    }
    if let draft = drafts.removeValue(forKey: lease.key) {
      releaseFinalizedDraft(
        draft, project: projectKey(lease.projectPath, lease.metadata))
      let leased = lease.acquired ? Set(lease.descriptors) : []
      let staged = Set(draft.files.values).subtracting(leased)
      _ = await removeDraftFiles(
        owner: draft.owner,
        context: AttachmentTransferContext(
          projectPath: lease.projectPath, metadata: lease.metadata, nodeID: lease.nodeID),
        projectIdentity: lease.projectIdentity, files: staged)
    }
    guard persistCatalog() else { return .failure(.transportFailure) }
    return leaseCleanupPending || cleanupQueue.values.contains(where: { $0.leaseID == leaseID })
      ? .failure(.transportFailure) : .success(())
  }

  public func discardDraft(
    owner: UUID, projectPath: String, metadata: ProjectMetadata, nodeID: UUID
  ) async -> Result<Void, RemoteAssetError> {
    await maintainFinalizedDrafts()
    let key = nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID)
    guard let draft = drafts[key] else { return .success(()) }
    guard draft.owner == owner else { return .failure(.unauthorized) }
    guard draft.leaseID == nil else { return .failure(.invalidReference) }
    return await abandonDraft(key: key) ? .success(()) : .failure(.transportFailure)
  }

  public func discardNode(
    projectPath: String, metadata: ProjectMetadata, nodeID: UUID
  ) async {
    let key = nodeKey(projectPath: projectPath, metadata: metadata, nodeID: nodeID)
    if let draft = drafts.removeValue(forKey: key) {
      releaseFinalizedDraft(draft, project: projectKey(projectPath, metadata))
      if let leaseID = draft.leaseID { draftLeases.removeValue(forKey: leaseID) }
    }
    await transport.discardAttachments(projectPath, metadata, nodeID)
    scheduleDraftExpiry()
  }

  public func reconcile(
    projectPath: String, metadata: ProjectMetadata, graphNodeIDs: Set<UUID>
  ) async {
    await maintainFinalizedDrafts()
    let identity = RemoteAssetIdentity.project(projectPath, metadata)
    for leaseID in draftLeases.keys where draftLeases[leaseID]?.projectIdentity == identity {
      draftLeases[leaseID]?.projectPath = projectPath
    }
    for key in cleanupQueue.keys where cleanupQueue[key]?.projectIdentity == identity {
      cleanupQueue[key]?.context.projectPath = projectPath
    }
    for key in drafts.keys where drafts[key]?.projectIdentity == identity {
      drafts[key]?.projectPath = projectPath
    }
    let leases = draftLeases.filter {
      $0.value.projectIdentity == identity
    }
    for (leaseID, lease) in leases {
      if graphNodeIDs.contains(lease.nodeID) {
        switch await finalizeCreate(
          leaseID: leaseID, retainedNames: Set(lease.descriptors.map(\.name)))
        {
        case .success:
          break
        case .failure:
          break
        }
      } else {
        _ = await rollbackCreate(leaseID: leaseID)
      }
    }
    await maintainFinalizedDrafts()
    _ = persistCatalog()
  }

  public func resourceUsage() async -> RemoteAssetUsageSnapshot {
    await maintainFinalizedDrafts()
    return RemoteAssetUsageSnapshot(
      activeTransfers: globalUsage.count, declaredBytes: globalUsage.declaredBytes,
      bufferedBytes: globalUsage.bufferedBytes,
      pendingDeliveries: pendingDeliveries.count,
      finalizedDrafts: globalDraftUsage.drafts,
      finalizedAttachments: globalDraftUsage.attachments,
      finalizedBytes: globalDraftUsage.bytes,
      pendingDraftCleanups: cleanupQueue.values.filter { $0.status == .pending }.count,
      quarantinedDraftCleanups: cleanupQueue.values.filter { $0.status == .quarantined }.count)
  }

  private var allTransfers: [Transfer] {
    Array(transfers.values) + finalizations.values.map(\.transfer)
      + pendingDeliveries.values.map(\.transfer)
  }

  private func maintainFinalizedDrafts() async {
    let current = now()
    let due = cleanupQueue.values.filter {
      $0.status == .pending && !$0.context.projectPath.isEmpty && $0.nextAttemptAt <= current
    }
    for record in due {
      do {
        switch record.target {
        case .staged:
          try await transport.removeAttachment(
            record.context.projectPath, record.context.metadata, record.context.nodeID,
            record.descriptor.name)
        case .lease:
          guard let leaseID = record.leaseID else {
            throw RemoteAssetError.invalidReference
          }
          try await transport.rollbackAttachmentLease(
            record.context.projectPath, record.context.metadata, record.context.nodeID, leaseID,
            [record.descriptor])
        }
        cleanupQueue.removeValue(forKey: record.key)
      } catch {
        var failed = record
        failed.attempts += 1
        failed.lastError = String(describing: error)
        if failed.attempts >= Self.maximumCleanupAttempts || current >= failed.deadline {
          failed.status = .quarantined
        } else {
          let exponent = min(failed.attempts, 10)
          failed.nextAttemptAt = current.addingTimeInterval(
            min(3_600, pow(2, Double(exponent))))
        }
        cleanupQueue[record.key] = failed
      }
    }

    let pendingDeliveryNames = Set(
      pendingDeliveries.values.map {
        nodeKey(
          projectPath: $0.transfer.projectPath, metadata: $0.transfer.metadata,
          nodeID: $0.transfer.nodeID) + "\u{0}" + $0.transfer.declaration.name
      })
    let provisional = drafts.filter { entry in
      entry.value.leaseID == nil
        && entry.value.provisional.contains { name in
          !pendingDeliveryNames.contains(entry.key + "\u{0}" + name)
        }
    }.map(\.key)
    for key in provisional {
      guard var draft = drafts[key] else { continue }
      for name in draft.provisional {
        guard !pendingDeliveryNames.contains(key + "\u{0}" + name) else { continue }
        guard let descriptor = draft.files.removeValue(forKey: name) else { continue }
        enqueueCleanup(
          context: AttachmentTransferContext(
            projectPath: draft.projectPath, metadata: draft.metadata, nodeID: draft.nodeID),
          descriptor: descriptor, projectIdentity: draft.projectIdentity, leaseID: nil,
          target: .staged)
        releaseFinalizedFile(
          owner: draft.owner, project: projectKey(draft.projectPath, draft.metadata),
          size: descriptor.size, removesDraft: draft.files.isEmpty)
      }
      draft.provisional = draft.provisional.filter {
        pendingDeliveryNames.contains(key + "\u{0}" + $0)
      }
      if draft.files.isEmpty {
        drafts.removeValue(forKey: key)
      } else {
        drafts[key] = draft
      }
    }

    let expired = drafts.filter { $0.value.leaseID == nil && $0.value.expiresAt <= current }.map(
      \.key)
    for key in expired {
      _ = await abandonDraft(key: key)
    }
    _ = persistCatalog()
    scheduleDraftExpiry()
  }

  private func scheduleDraftExpiry() {
    draftExpiryTask?.cancel()
    let expiry = drafts.values.filter { $0.leaseID == nil }.map(\.expiresAt).min()
    let cleanup = cleanupQueue.values.filter {
      $0.status == .pending && !$0.context.projectPath.isEmpty
    }.map(\.nextAttemptAt).min()
    let pendingDeliveryNames = Set(
      pendingDeliveries.values.map {
        nodeKey(
          projectPath: $0.transfer.projectPath, metadata: $0.transfer.metadata,
          nodeID: $0.transfer.nodeID) + "\u{0}" + $0.transfer.declaration.name
      })
    let hasProvisional = drafts.contains { entry in
      entry.value.provisional.contains {
        !pendingDeliveryNames.contains(entry.key + "\u{0}" + $0)
      }
    }
    guard expiry != nil || cleanup != nil || hasProvisional else {
      draftExpiryTask = nil
      return
    }
    let next = [expiry, cleanup].compactMap { $0 }.min() ?? now()
    let delay: TimeInterval = hasProvisional ? 0 : max(0, next.timeIntervalSince(now()))
    draftExpiryTask = Task { [weak self] in
      let nanoseconds = UInt64(min(delay, 24 * 60 * 60) * 1_000_000_000)
      if nanoseconds > 0 {
        try? await Task.sleep(nanoseconds: nanoseconds)
      }
      guard !Task.isCancelled else { return }
      await self?.maintainFinalizedDrafts()
    }
  }

  private func reserveFinalizedDraft(
    owner: UUID, project: String, createsDraft: Bool, bytes: Int
  ) -> Bool {
    let ownerValue = ownerDraftUsage[owner] ?? DraftUsage()
    let projectValue = projectDraftUsage[project] ?? DraftUsage()
    let draftDelta = createsDraft ? 1 : 0
    guard
      canAdd(ownerValue.drafts, draftDelta, limit: Self.maximumFinalizedDraftsPerOwner),
      canAdd(projectValue.drafts, draftDelta, limit: Self.maximumFinalizedDraftsPerProject),
      canAdd(globalDraftUsage.drafts, draftDelta, limit: Self.maximumFinalizedDraftsGlobal),
      canAdd(
        ownerValue.attachments, 1, limit: Self.maximumFinalizedAttachmentsPerOwner),
      canAdd(
        projectValue.attachments, 1, limit: Self.maximumFinalizedAttachmentsPerProject),
      canAdd(
        globalDraftUsage.attachments, 1, limit: Self.maximumFinalizedAttachmentsGlobal),
      canAdd(ownerValue.bytes, bytes, limit: Self.maximumFinalizedBytesPerOwner),
      canAdd(projectValue.bytes, bytes, limit: Self.maximumFinalizedBytesPerProject),
      canAdd(globalDraftUsage.bytes, bytes, limit: Self.maximumFinalizedBytesGlobal)
    else { return false }
    ownerDraftUsage[owner] = adding(
      ownerValue, drafts: draftDelta, attachments: 1, bytes: bytes)
    projectDraftUsage[project] = adding(
      projectValue, drafts: draftDelta, attachments: 1, bytes: bytes)
    globalDraftUsage = adding(
      globalDraftUsage, drafts: draftDelta, attachments: 1, bytes: bytes)
    return true
  }

  private func cleanupCapacityAvailable(addingCount: Int, addingBytes: Int) -> Bool {
    var count = cleanupQueue.count
    var bytes = 0
    for record in cleanupQueue.values {
      guard canAdd(bytes, record.descriptor.size, limit: Self.maximumCleanupBytes) else {
        return false
      }
      bytes += record.descriptor.size
    }
    guard canAdd(count, globalDraftUsage.attachments, limit: Self.maximumCleanupRecords),
      canAdd(bytes, globalDraftUsage.bytes, limit: Self.maximumCleanupBytes)
    else { return false }
    count += globalDraftUsage.attachments
    bytes += globalDraftUsage.bytes
    for finalization in finalizations.values {
      guard canAdd(count, 1, limit: Self.maximumCleanupRecords),
        canAdd(
          bytes, finalization.transfer.declaration.size,
          limit: Self.maximumCleanupBytes)
      else { return false }
      count += 1
      bytes += finalization.transfer.declaration.size
    }
    for lease in draftLeases.values where drafts[lease.key] == nil {
      for descriptor in lease.descriptors {
        guard canAdd(count, 1, limit: Self.maximumCleanupRecords),
          canAdd(bytes, descriptor.size, limit: Self.maximumCleanupBytes)
        else { return false }
        count += 1
        bytes += descriptor.size
      }
    }
    return canAdd(count, addingCount, limit: Self.maximumCleanupRecords)
      && canAdd(bytes, addingBytes, limit: Self.maximumCleanupBytes)
  }

  private func releaseFinalizedDraft(_ draft: DraftState, project: String) {
    let bytes = draft.files.values.reduce(0) { partial, value in
      partial.addingReportingOverflow(value.size).overflow ? Int.max : partial + value.size
    }
    ownerDraftUsage[draft.owner] = subtracting(
      ownerDraftUsage[draft.owner] ?? DraftUsage(), drafts: 1,
      attachments: draft.files.count, bytes: bytes)
    projectDraftUsage[project] = subtracting(
      projectDraftUsage[project] ?? DraftUsage(), drafts: 1,
      attachments: draft.files.count, bytes: bytes)
    globalDraftUsage = subtracting(
      globalDraftUsage, drafts: 1, attachments: draft.files.count, bytes: bytes)
    if let usage = ownerDraftUsage[draft.owner], isEmpty(usage) {
      ownerDraftUsage.removeValue(forKey: draft.owner)
    }
    if let usage = projectDraftUsage[project], isEmpty(usage) {
      projectDraftUsage.removeValue(forKey: project)
    }
  }

  private func abandonDraft(key: String, leaseID: UUID? = nil) async -> Bool {
    guard let draft = drafts[key],
      leaseID == nil || draft.leaseID == leaseID
    else { return true }
    let context = AttachmentTransferContext(
      projectPath: draft.projectPath, metadata: draft.metadata, nodeID: draft.nodeID)
    drafts.removeValue(forKey: key)
    if let activeLease = draft.leaseID {
      draftLeases.removeValue(forKey: activeLease)
    }
    releaseFinalizedDraft(draft, project: projectKey(context.projectPath, context.metadata))
    let removed = await removeDraftFiles(
      owner: draft.owner, context: context, projectIdentity: draft.projectIdentity,
      files: Set(draft.files.values))
    _ = persistCatalog()
    scheduleDraftExpiry()
    return removed
  }

  private func removeDraftFiles(
    owner: UUID, context: AttachmentTransferContext, projectIdentity: String? = nil,
    files: Set<RemoteAssetRetentionDescriptor>
  ) async -> Bool {
    _ = owner
    var removed = true
    for descriptor in files {
      if !(await removeDraftFile(context: context, name: descriptor.name)) {
        enqueueCleanup(
          context: context, descriptor: descriptor, projectIdentity: projectIdentity,
          leaseID: nil, target: .staged)
        removed = false
      }
    }
    _ = persistCatalog()
    scheduleDraftExpiry()
    return removed
  }

  private func removeDraftFile(context: AttachmentTransferContext, name: String) async -> Bool {
    for attempt in 0..<3 {
      do {
        try await transport.removeAttachment(
          context.projectPath, context.metadata, context.nodeID, name)
        return true
      } catch {
        if attempt < 2 { await Task.yield() }
      }
    }
    return false
  }

  private func retentionDescriptor(
    for declaration: AttachmentUploadDeclaration
  ) -> RemoteAssetRetentionDescriptor {
    RemoteAssetRetentionDescriptor(
      name: declaration.name, size: declaration.size, sha256: declaration.sha256)
  }

  private func legacyRetentionDescriptor(
    _ attachment: PromptAttachment, projectPath: String, nodeID: UUID
  ) -> RemoteAssetRetentionDescriptor? {
    let directory = attachmentsDirectory(projectPath, nodeID).standardizedFileURL
    let candidate = URL(fileURLWithPath: attachment.path).standardizedFileURL
    guard candidate.deletingLastPathComponent() == directory,
      candidate.lastPathComponent == attachment.fileName,
      let data = try? SafeLocalFile.read(
        candidate, maximumBytes: AttachmentUploadDeclaration.maximumFileBytes)
    else { return nil }
    return RemoteAssetRetentionDescriptor(
      name: attachment.fileName, size: data.count,
      sha256: RemoteAssetDigest.sha256Hex(data))
  }

  private func releaseFinalizedFile(
    owner: UUID, project: String, size: Int, removesDraft: Bool
  ) {
    let draftDelta = removesDraft ? 1 : 0
    ownerDraftUsage[owner] = subtracting(
      ownerDraftUsage[owner] ?? DraftUsage(), drafts: draftDelta, attachments: 1, bytes: size)
    projectDraftUsage[project] = subtracting(
      projectDraftUsage[project] ?? DraftUsage(), drafts: draftDelta, attachments: 1, bytes: size)
    globalDraftUsage = subtracting(
      globalDraftUsage, drafts: draftDelta, attachments: 1, bytes: size)
    if let usage = ownerDraftUsage[owner], isEmpty(usage) {
      ownerDraftUsage.removeValue(forKey: owner)
    }
    if let usage = projectDraftUsage[project], isEmpty(usage) {
      projectDraftUsage.removeValue(forKey: project)
    }
  }

  private func enqueueCleanup(for transfer: Transfer, target: CleanupTarget) {
    enqueueCleanup(
      context: AttachmentTransferContext(
        projectPath: transfer.projectPath, metadata: transfer.metadata, nodeID: transfer.nodeID),
      descriptor: retentionDescriptor(for: transfer.declaration), leaseID: nil, target: target)
  }

  private func enqueueCleanup(
    context: AttachmentTransferContext, descriptor: RemoteAssetRetentionDescriptor,
    projectIdentity: String? = nil, leaseID: UUID?, target: CleanupTarget
  ) {
    let identity =
      projectIdentity ?? RemoteAssetIdentity.project(context.projectPath, context.metadata)
    let key = cleanupKey(
      projectIdentity: identity, nodeID: context.nodeID, descriptor: descriptor,
      leaseID: leaseID, target: target)
    guard cleanupQueue[key] == nil else { return }
    let bytes = cleanupQueue.values.reduce(0) { partial, record in
      let added = partial.addingReportingOverflow(record.descriptor.size)
      return added.overflow ? Int.max : added.partialValue
    }
    guard cleanupQueue.count < Self.maximumCleanupRecords,
      canAdd(bytes, descriptor.size, limit: Self.maximumCleanupBytes)
    else { return }
    let current = now()
    cleanupQueue[key] = CleanupRecord(
      key: key, context: context, projectIdentity: identity, descriptor: descriptor,
      leaseID: leaseID, target: target,
      attempts: 0, nextAttemptAt: current,
      deadline: current.addingTimeInterval(
        Self.cleanupLifetime), status: .pending, lastError: nil)
    _ = persistCatalog()
    scheduleDraftExpiry()
  }

  private func cleanupKey(
    projectIdentity: String, nodeID: UUID, descriptor: RemoteAssetRetentionDescriptor,
    leaseID: UUID?, target: CleanupTarget
  ) -> String {
    RemoteAssetDigest.sha256Hex(
      Data(
        "\(projectIdentity)\0\(nodeID)\0\(descriptor.name)\0\(descriptor.sha256)\0\(leaseID?.uuidString ?? "")\0\(target.rawValue)"
          .utf8))
  }

  @discardableResult
  private func persistCatalog() -> Bool {
    guard let catalogURL else { return true }
    let catalog = DurableCatalog(
      version: 1, drafts: drafts, leases: draftLeases, cleanup: cleanupQueue)
    guard let data = try? JSONEncoder().encode(catalog) else { return false }
    do {
      try FileManager.default.createDirectory(
        at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: catalogURL, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private static func loadCatalog(from catalogURL: URL?) -> DurableCatalog {
    let empty = DurableCatalog(version: 1, drafts: [:], leases: [:], cleanup: [:])
    guard let catalogURL, FileManager.default.fileExists(atPath: catalogURL.path) else {
      return empty
    }
    do {
      let data = try Data(contentsOf: catalogURL)
      let catalog = try JSONDecoder().decode(DurableCatalog.self, from: data)
      var cleanupBytes = 0
      var draftBytes = 0
      var draftAttachments = 0
      var orphanLeaseBytes = 0
      var orphanLeaseAttachments = 0
      guard catalog.version == 1, catalog.cleanup.count <= maximumCleanupRecords,
        catalog.drafts.count <= maximumFinalizedDraftsGlobal,
        catalog.leases.count <= maximumCleanupRecords
      else { throw RemoteAssetError.invalidReference }
      for record in catalog.cleanup.values {
        guard valid(record.descriptor),
          record.key
            == cleanupKey(
              projectIdentity: record.projectIdentity, nodeID: record.context.nodeID,
              descriptor: record.descriptor, leaseID: record.leaseID, target: record.target),
          !cleanupBytes.addingReportingOverflow(record.descriptor.size).overflow
        else { throw RemoteAssetError.invalidReference }
        cleanupBytes += record.descriptor.size
      }
      guard cleanupBytes <= maximumCleanupBytes else {
        throw RemoteAssetError.invalidReference
      }
      for (key, draft) in catalog.drafts {
        guard key == "\(draft.projectIdentity)\u{0}\(draft.nodeID.uuidString)",
          draft.files.count <= AttachmentUploadDeclaration.maximumFilesPerNode,
          draft.provisional.isSubset(of: Set(draft.files.keys)),
          draft.files.allSatisfy({ $0.key == $0.value.name && valid($0.value) }),
          !draftAttachments.addingReportingOverflow(draft.files.count).overflow
        else { throw RemoteAssetError.invalidReference }
        draftAttachments += draft.files.count
        for descriptor in draft.files.values {
          guard !draftBytes.addingReportingOverflow(descriptor.size).overflow else {
            throw RemoteAssetError.invalidReference
          }
          draftBytes += descriptor.size
        }
      }
      guard draftAttachments <= maximumFinalizedAttachmentsGlobal,
        draftBytes <= maximumFinalizedBytesGlobal,
        canAddStatic(
          catalog.cleanup.count, draftAttachments, limit: maximumCleanupRecords),
        canAddStatic(cleanupBytes, draftBytes, limit: maximumCleanupBytes)
      else { throw RemoteAssetError.invalidReference }
      for (leaseID, lease) in catalog.leases {
        guard lease.key == "\(lease.projectIdentity)\u{0}\(lease.nodeID.uuidString)",
          !lease.descriptors.isEmpty, lease.descriptors.allSatisfy(valid),
          catalog.drafts[lease.key]?.leaseID == leaseID
            || catalog.drafts[lease.key] == nil,
          lease.createdAt <= lease.expiresAt
        else { throw RemoteAssetError.invalidReference }
        if catalog.drafts[lease.key] == nil {
          guard
            !orphanLeaseAttachments.addingReportingOverflow(lease.descriptors.count).overflow
          else { throw RemoteAssetError.invalidReference }
          orphanLeaseAttachments += lease.descriptors.count
          for descriptor in lease.descriptors {
            guard !orphanLeaseBytes.addingReportingOverflow(descriptor.size).overflow else {
              throw RemoteAssetError.invalidReference
            }
            orphanLeaseBytes += descriptor.size
          }
        }
      }
      guard
        canAddStatic(
          catalog.cleanup.count + draftAttachments, orphanLeaseAttachments,
          limit: maximumCleanupRecords),
        canAddStatic(cleanupBytes + draftBytes, orphanLeaseBytes, limit: maximumCleanupBytes)
      else {
        throw RemoteAssetError.invalidReference
      }
      return catalog
    } catch {
      quarantineCatalog(at: catalogURL)
      return empty
    }
  }

  private static func quarantineCatalog(at catalogURL: URL) {
    let directory = catalogURL.deletingLastPathComponent()
    let stem = catalogURL.deletingPathExtension().lastPathComponent + ".corrupt-"
    let quarantine = directory.appendingPathComponent(
      "\(stem)\(UUID().uuidString).json")
    try? FileManager.default.moveItem(at: catalogURL, to: quarantine)
    guard
      let candidates = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
      .filter({ $0.lastPathComponent.hasPrefix(stem) })
      .sorted(by: {
        let lhsValues = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
        let rhsValues = try? $1.resourceValues(forKeys: [.contentModificationDateKey])
        let lhs = lhsValues?.contentModificationDate ?? .distantPast
        let rhs = rhsValues?.contentModificationDate ?? .distantPast
        return lhs > rhs
      }),
      candidates.count > 8
    else { return }
    for candidate in candidates.dropFirst(8) {
      try? FileManager.default.removeItem(at: candidate)
    }
  }

  private static func valid(_ descriptor: RemoteAssetRetentionDescriptor) -> Bool {
    AttachmentUploadDeclaration.isSafeName(descriptor.name)
      && descriptor.size > 0
      && descriptor.size <= AttachmentUploadDeclaration.maximumFileBytes
      && descriptor.sha256.count == 64
      && descriptor.sha256.allSatisfy(\.isHexDigit)
  }

  private static func canAddStatic(_ lhs: Int, _ rhs: Int, limit: Int) -> Bool {
    let result = lhs.addingReportingOverflow(rhs)
    return !result.overflow && result.partialValue <= limit
  }

  private static func cleanupKey(
    projectIdentity: String, nodeID: UUID, descriptor: RemoteAssetRetentionDescriptor,
    leaseID: UUID?, target: CleanupTarget
  ) -> String {
    RemoteAssetDigest.sha256Hex(
      Data(
        "\(projectIdentity)\0\(nodeID)\0\(descriptor.name)\0\(descriptor.sha256)\0\(leaseID?.uuidString ?? "")\0\(target.rawValue)"
          .utf8))
  }

  private func adding(
    _ usage: DraftUsage, drafts: Int, attachments: Int, bytes: Int
  ) -> DraftUsage {
    DraftUsage(
      drafts: usage.drafts + drafts, attachments: usage.attachments + attachments,
      bytes: usage.bytes + bytes)
  }

  private func subtracting(
    _ usage: DraftUsage, drafts: Int, attachments: Int, bytes: Int
  ) -> DraftUsage {
    DraftUsage(
      drafts: max(0, usage.drafts - drafts),
      attachments: max(0, usage.attachments - attachments),
      bytes: max(0, usage.bytes - bytes))
  }

  private func isEmpty(_ usage: DraftUsage) -> Bool {
    usage.drafts == 0 && usage.attachments == 0 && usage.bytes == 0
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
    "\(RemoteAssetIdentity.project(projectPath, metadata))\u{0}\(nodeID.uuidString)"
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
    let retained = retainedAttachment(
      directory: directory,
      descriptor: RemoteAssetRetentionDescriptor(name: name, size: size, sha256: sha256))
    let destination =
      FileManager.default.fileExists(atPath: retained.path)
      ? retained : directory.appendingPathComponent(name)
    try SafeLocalFile.validateDirectory(directory)
    let data = try SafeLocalFile.read(destination, maximumBytes: size)
    guard data.count == size, RemoteAssetDigest.sha256Hex(data) == sha256 else {
      throw RemoteAssetError.hashMismatch
    }
    return destination.path
  }

  static func retainAttachments(projectPath: String, nodeID: UUID, names: Set<String>) throws {
    let directory = NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      if names.isEmpty { return }
      throw RemoteAssetError.missing
    }
    try SafeLocalFile.validateDirectory(directory)
    for name in names {
      guard AttachmentUploadDeclaration.isSafeName(name) else {
        throw RemoteAssetError.invalidReference
      }
      _ = try SafeLocalFile.read(
        directory.appendingPathComponent(name),
        maximumBytes: AttachmentUploadDeclaration.maximumFileBytes)
    }
  }

  static func acquireAttachmentLease(
    projectPath: String, nodeID: UUID, leaseID: UUID,
    descriptors: [RemoteAssetRetentionDescriptor]
  ) throws {
    let directory = NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
    try SafeLocalFile.validateDirectory(directory)
    let lease = leaseDirectory(directory: directory, leaseID: leaseID)
    guard !FileManager.default.fileExists(atPath: lease.path) else {
      throw RemoteAssetError.invalidReference
    }
    try FileManager.default.createDirectory(at: lease, withIntermediateDirectories: true)
    do {
      for descriptor in descriptors {
        guard AttachmentUploadDeclaration.isSafeName(descriptor.name) else {
          throw RemoteAssetError.invalidReference
        }
        let source = directory.appendingPathComponent(descriptor.name)
        let destination = lease.appendingPathComponent(descriptor.name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
          throw RemoteAssetError.invalidReference
        }
        try FileManager.default.moveItem(at: source, to: destination)
        try verify(destination, descriptor: descriptor)
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o400], ofItemAtPath: destination.path)
      }
      try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lease.path)
    } catch {
      try? rollbackAttachmentLease(
        projectPath: projectPath, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
      throw error
    }
  }

  static func verifyAttachmentLease(
    projectPath: String, nodeID: UUID, leaseID: UUID,
    descriptors: [RemoteAssetRetentionDescriptor]
  ) throws {
    let directory = NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
    for descriptor in descriptors {
      let leased = leaseDirectory(directory: directory, leaseID: leaseID)
        .appendingPathComponent(descriptor.name)
      let retained = retainedAttachment(directory: directory, descriptor: descriptor)
      let candidate = FileManager.default.fileExists(atPath: retained.path) ? retained : leased
      try verify(candidate, descriptor: descriptor)
    }
  }

  static func commitAttachmentLease(
    projectPath: String, nodeID: UUID, leaseID: UUID,
    descriptors: [RemoteAssetRetentionDescriptor]
  ) throws {
    let directory = NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
    try verifyAttachmentLease(
      projectPath: projectPath, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: leaseDirectory(directory: directory, leaseID: leaseID).path)
    for descriptor in descriptors {
      let source = leaseDirectory(directory: directory, leaseID: leaseID)
        .appendingPathComponent(descriptor.name)
      let destination = retainedAttachment(directory: directory, descriptor: descriptor)
      if FileManager.default.fileExists(atPath: destination.path) {
        try verify(destination, descriptor: descriptor)
        continue
      }
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: source, to: destination)
      try verify(destination, descriptor: descriptor)
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o400], ofItemAtPath: destination.path)
    }
    try removeLeaseDirectory(
      directory: directory, leaseID: leaseID, descriptors: descriptors)
  }

  static func rollbackAttachmentLease(
    projectPath: String, nodeID: UUID, leaseID: UUID,
    descriptors: [RemoteAssetRetentionDescriptor]
  ) throws {
    let directory = NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
    try removeLeaseDirectory(
      directory: directory, leaseID: leaseID, descriptors: descriptors)
  }

  static func resolveLeasedAttachment(
    projectPath: String, nodeID: UUID, leaseID: UUID,
    descriptor: RemoteAssetRetentionDescriptor
  ) throws -> String {
    let directory = NodeMemory.attachmentsDirectory(forProjectPath: projectPath, nodeID: nodeID)
    let retained = retainedAttachment(directory: directory, descriptor: descriptor)
    let leased = leaseDirectory(directory: directory, leaseID: leaseID)
      .appendingPathComponent(descriptor.name)
    let candidate = FileManager.default.fileExists(atPath: retained.path) ? retained : leased
    try verify(candidate, descriptor: descriptor)
    return candidate.path
  }

  private static func leaseDirectory(directory: URL, leaseID: UUID) -> URL {
    directory.appendingPathComponent(".leases", isDirectory: true)
      .appendingPathComponent(leaseID.uuidString, isDirectory: true)
  }

  private static func retainedAttachment(
    directory: URL, descriptor: RemoteAssetRetentionDescriptor
  ) -> URL {
    let key = RemoteAssetDigest.pathKey(sha256: descriptor.sha256) ?? descriptor.sha256
    return directory.appendingPathComponent(".retained", isDirectory: true)
      .appendingPathComponent(key)
  }

  private static func removeLeaseDirectory(
    directory: URL, leaseID: UUID, descriptors: [RemoteAssetRetentionDescriptor]
  ) throws {
    let leases = directory.appendingPathComponent(".leases", isDirectory: true)
    let leaseName = leaseID.uuidString
    #if os(Windows)
      let lease = leases.appendingPathComponent(leaseName, isDirectory: true)
      let cleanup = leases.appendingPathComponent(
        ".c-\(leaseName.replacingOccurrences(of: "-", with: ""))", isDirectory: true)
      let stable: StableProjectDirectory
      if FileManager.default.fileExists(atPath: cleanup.path) {
        stable = try StableProjectDirectory(path: cleanup.path)
      } else {
        guard FileManager.default.fileExists(atPath: lease.path) else { return }
        stable = try StableProjectDirectory(path: lease.path)
        try stable.rename(to: cleanup.path)
      }
      for descriptor in descriptors {
        try stable.verify(path: cleanup.path)
        let candidate = cleanup.appendingPathComponent(descriptor.name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
        try verify(candidate, descriptor: descriptor)
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: candidate.path)
        try FileManager.default.removeItem(at: candidate)
      }
      try stable.verify(path: cleanup.path)
      try FileManager.default.removeItem(at: cleanup)
    #else
      let parentDescriptor = leases.path.withCString { path in
        #if canImport(Darwin)
          Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        #else
          Glibc.open(path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        #endif
      }
      guard parentDescriptor >= 0 else {
        if !FileManager.default.fileExists(atPath: leases.path) { return }
        throw RemoteAssetError.unsafeFile
      }
      defer {
        #if canImport(Darwin)
          _ = Darwin.close(parentDescriptor)
        #else
          _ = Glibc.close(parentDescriptor)
        #endif
      }
      let leaseDescriptor = leaseName.withCString { name in
        #if canImport(Darwin)
          Darwin.openat(parentDescriptor, name, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        #else
          Glibc.openat(parentDescriptor, name, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        #endif
      }
      guard leaseDescriptor >= 0 else { return }
      defer {
        #if canImport(Darwin)
          _ = Darwin.close(leaseDescriptor)
        #else
          _ = Glibc.close(leaseDescriptor)
        #endif
      }
      _ = fchmod(leaseDescriptor, mode_t(0o700))
      for descriptor in descriptors {
        let result = descriptor.name.withCString { name in
          #if canImport(Darwin)
            Darwin.unlinkat(leaseDescriptor, name, 0)
          #else
            Glibc.unlinkat(leaseDescriptor, name, 0)
          #endif
        }
        if result != 0 {
          #if canImport(Darwin)
            guard Darwin.errno == ENOENT else { throw RemoteAssetError.unsafeFile }
          #else
            guard Glibc.errno == ENOENT else { throw RemoteAssetError.unsafeFile }
          #endif
        }
      }
      let removed = leaseName.withCString { name in
        #if canImport(Darwin)
          Darwin.unlinkat(parentDescriptor, name, AT_REMOVEDIR)
        #else
          Glibc.unlinkat(parentDescriptor, name, AT_REMOVEDIR)
        #endif
      }
      guard removed == 0 else { throw RemoteAssetError.unsafeFile }
    #endif
  }

  private static func verify(_ url: URL, descriptor: RemoteAssetRetentionDescriptor) throws {
    let data = try SafeLocalFile.read(url, maximumBytes: descriptor.size)
    guard data.count == descriptor.size,
      RemoteAssetDigest.sha256Hex(data) == descriptor.sha256
    else { throw RemoteAssetError.hashMismatch }
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
      import base64,hashlib,os,stat,sys
      ident,node,name,size,digest=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4]),sys.argv[5]
      root=os.path.expanduser(os.path.join("~/.graphcode/staging",ident,node))
      key=base64.urlsafe_b64encode(bytes.fromhex(digest)).decode("ascii").rstrip("=")
      retained=os.path.join(root,".retained",key)
      p=retained if os.path.lexists(retained) else os.path.join(root,name)
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
      if not os.path.lexists(root): raise SystemExit(0 if not allowed else 2)
      rs=os.lstat(root)
      if not stat.S_ISDIR(rs.st_mode) or stat.S_ISLNK(rs.st_mode): raise SystemExit(2)
      for name in allowed:
       p=os.path.join(root,name); s=os.lstat(p)
       if not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_nlink != 1: raise SystemExit(3)
      """
    _ = try await run(
      location: location, script: script, arguments: [identity, nodeID.uuidString],
      input: encodedNames, maximumOutputBytes: 1024)
  }

  static func acquireAttachmentLease(
    projectPath: String, locationKind: ProjectLocationKind, nodeID: UUID, leaseID: UUID,
    descriptors: [RemoteAssetRetentionDescriptor]
  ) async throws {
    try await leaseOperation(
      projectPath: projectPath, locationKind: locationKind, nodeID: nodeID, leaseID: leaseID,
      descriptors: descriptors, operation: "acquire")
  }

  static func verifyAttachmentLease(
    projectPath: String, locationKind: ProjectLocationKind, nodeID: UUID, leaseID: UUID,
    descriptors: [RemoteAssetRetentionDescriptor]
  ) async throws {
    try await leaseOperation(
      projectPath: projectPath, locationKind: locationKind, nodeID: nodeID, leaseID: leaseID,
      descriptors: descriptors, operation: "verify")
  }

  static func commitAttachmentLease(
    projectPath: String, locationKind: ProjectLocationKind, nodeID: UUID, leaseID: UUID,
    descriptors: [RemoteAssetRetentionDescriptor]
  ) async throws {
    try await leaseOperation(
      projectPath: projectPath, locationKind: locationKind, nodeID: nodeID, leaseID: leaseID,
      descriptors: descriptors, operation: "commit")
  }

  static func rollbackAttachmentLease(
    projectPath: String, locationKind: ProjectLocationKind, nodeID: UUID, leaseID: UUID,
    descriptors: [RemoteAssetRetentionDescriptor]
  ) async throws {
    try await leaseOperation(
      projectPath: projectPath, locationKind: locationKind, nodeID: nodeID, leaseID: leaseID,
      descriptors: descriptors, operation: "rollback")
  }

  static func resolveLeasedAttachment(
    projectPath: String, locationKind: ProjectLocationKind, nodeID: UUID, leaseID: UUID,
    descriptor: RemoteAssetRetentionDescriptor
  ) async throws -> String {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath) else {
      throw RemoteAssetError.unauthorized
    }
    let identity = RemoteAssetIdentity.project(projectPath, locationKind)
    let encoded = try JSONEncoder().encode([descriptor])
    let data = try await run(
      location: location, script: leaseScript,
      arguments: [identity, nodeID.uuidString, leaseID.uuidString, "resolve"],
      input: encoded, maximumOutputBytes: 4096)
    guard
      let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty
    else { throw RemoteAssetError.transportFailure }
    return path
  }

  private static func leaseOperation(
    projectPath: String, locationKind: ProjectLocationKind, nodeID: UUID, leaseID: UUID,
    descriptors: [RemoteAssetRetentionDescriptor], operation: String
  ) async throws {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath) else {
      throw RemoteAssetError.unauthorized
    }
    let identity = RemoteAssetIdentity.project(projectPath, locationKind)
    let encoded = try JSONEncoder().encode(descriptors)
    _ = try await run(
      location: location, script: leaseScript,
      arguments: [identity, nodeID.uuidString, leaseID.uuidString, operation],
      input: encoded, maximumOutputBytes: 4096)
  }

  private static let leaseScript = """
    import base64,hashlib,json,os,stat,sys
    ident,node,lease,op=sys.argv[1:5]
    items=json.load(sys.stdin)
    root=os.path.expanduser(os.path.join("~/.graphcode/staging",ident,node))
    lease_root=os.path.join(root,".leases",lease)
    retained_root=os.path.join(root,".retained")
    def retained_name(item):
     return base64.urlsafe_b64encode(bytes.fromhex(item["sha256"])).decode("ascii").rstrip("=")
    def mkdir_safe(p):
     if os.path.lexists(p):
      s=os.lstat(p)
      if not stat.S_ISDIR(s.st_mode) or stat.S_ISLNK(s.st_mode): raise SystemExit(2)
     else: os.mkdir(p,0o700)
    def open_dir(p):
     fd=os.open(p,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)|getattr(os,"O_DIRECTORY",0))
     s=os.fstat(fd)
     if not stat.S_ISDIR(s.st_mode) or stat.S_ISLNK(s.st_mode):
      os.close(fd); raise SystemExit(2)
     return fd
    def checked_at(parent,name,item):
     fd=-1
     try:
      fd=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=parent)
      s=os.fstat(fd)
      if not stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode) or s.st_nlink != 1 or s.st_size != item["size"]: raise SystemExit(3)
      os.lseek(fd,0,os.SEEK_SET)
      h=hashlib.sha256()
      while True:
       b=os.read(fd,65536)
       if not b: break
       h.update(b)
      if h.hexdigest()!=item["sha256"]: raise SystemExit(4)
     except OSError: raise SystemExit(5)
     finally:
      if fd>=0: os.close(fd)
    if op=="acquire":
     mkdir_safe(root); mkdir_safe(os.path.join(root,".leases")); mkdir_safe(lease_root)
     root_fd=open_dir(root); lease_fd=open_dir(lease_root)
     try:
      for item in items:
       checked_at(root_fd,item["name"],item)
       try: os.link(item["name"],item["name"],src_dir_fd=root_fd,dst_dir_fd=lease_fd,follow_symlinks=False)
       except FileExistsError: raise SystemExit(6)
       os.unlink(item["name"],dir_fd=root_fd); checked_at(lease_fd,item["name"],item)
       fd=os.open(item["name"],os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=lease_fd)
       os.fchmod(fd,0o400); os.close(fd)
      os.fchmod(lease_fd,0o500)
     finally:
      os.close(lease_fd); os.close(root_fd)
    elif op=="verify":
     lease_fd=open_dir(lease_root)
     retained_fd=open_dir(retained_root) if os.path.lexists(retained_root) else None
     try:
      for item in items:
       if retained_fd is not None:
        try:
         checked_at(retained_fd,retained_name(item),item); continue
        except SystemExit as e:
         if e.code != 5: raise
       checked_at(lease_fd,item["name"],item)
     finally:
      if retained_fd is not None: os.close(retained_fd)
      os.close(lease_fd)
    elif op=="commit":
     mkdir_safe(root); mkdir_safe(retained_root)
     lease_fd=open_dir(lease_root); retained_fd=open_dir(retained_root)
     try:
      os.fchmod(lease_fd,0o700)
      for item in items:
       name=retained_name(item)
       try:
        checked_at(retained_fd,name,item)
        checked_at(lease_fd,item["name"],item)
        os.unlink(item["name"],dir_fd=lease_fd)
        continue
       except SystemExit as e:
        if e.code != 5: raise
       checked_at(lease_fd,item["name"],item)
       os.link(item["name"],name,src_dir_fd=lease_fd,dst_dir_fd=retained_fd,follow_symlinks=False)
       os.unlink(item["name"],dir_fd=lease_fd); checked_at(retained_fd,name,item)
       fd=os.open(name,os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=retained_fd)
       os.fchmod(fd,0o400); os.close(fd)
     finally:
      os.close(retained_fd); os.close(lease_fd)
     os.rmdir(lease_root)
    elif op=="rollback":
     try: lease_fd=open_dir(lease_root)
     except FileNotFoundError: raise SystemExit(0)
     except OSError: raise SystemExit(7)
     try:
      os.fchmod(lease_fd,0o700)
      for item in items:
       try: checked_at(lease_fd,item["name"],item)
       except SystemExit as e:
        if e.code == 5: continue
        raise
       fd=os.open(item["name"],os.O_RDONLY|getattr(os,"O_NOFOLLOW",0),dir_fd=lease_fd)
       os.fchmod(fd,0o600); os.close(fd); os.unlink(item["name"],dir_fd=lease_fd)
     finally: os.close(lease_fd)
     os.rmdir(lease_root)
    elif op=="resolve":
     item=items[0]
     if os.path.lexists(retained_root):
      retained_fd=open_dir(retained_root)
      try:
       try:
        checked_at(retained_fd,retained_name(item),item)
        print(os.path.join(retained_root,retained_name(item))); raise SystemExit(0)
       except SystemExit as e:
        if e.code != 5: raise
      finally: os.close(retained_fd)
     lease_fd=open_dir(lease_root)
     try:
      checked_at(lease_fd,item["name"],item); print(os.path.join(lease_root,item["name"]))
     finally: os.close(lease_fd)
    else: raise SystemExit(8)
    """

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
