import Foundation

public struct RemoteTemplateListQuery: Codable, Equatable, Sendable {
  public static let defaultCount = 64
  public static let maximumCount = 128
  public static let defaultBytes = 256 * 1024
  public static let maximumBytes = 512 * 1024

  public var maxCount: Int
  public var maxBytes: Int

  public init(maxCount: Int = defaultCount, maxBytes: Int = defaultBytes) {
    self.maxCount = maxCount
    self.maxBytes = maxBytes
  }

  public func validated() throws -> Self {
    guard (1...Self.maximumCount).contains(maxCount),
      (1...Self.maximumBytes).contains(maxBytes)
    else { throw RemoteAssetError.invalidBounds }
    return self
  }
}
public struct RemoteTemplateReadQuery: Codable, Equatable, Sendable {
  public static let defaultBytes = 128 * 1024
  public static let maximumBytes = 256 * 1024

  public var templateID: UUID
  public var assetID: String?
  public var maxBytes: Int

  public init(templateID: UUID, assetID: String? = nil, maxBytes: Int = defaultBytes) {
    self.templateID = templateID
    self.assetID = assetID
    self.maxBytes = maxBytes
  }

  public func validated() throws -> Self {
    guard (1...Self.maximumBytes).contains(maxBytes) else {
      throw RemoteAssetError.invalidBounds
    }
    return self
  }
}
public struct RemoteTemplateMetadata: Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var fileName: String
  public var origin: TemplateOrigin
  public var assetID: String?

  public init(
    id: UUID, name: String, fileName: String, origin: TemplateOrigin, assetID: String? = nil
  ) {
    self.id = id
    self.name = name
    self.fileName = fileName
    self.origin = origin
    self.assetID = assetID
  }
}
public struct RemoteTemplateList: Codable, Equatable, Sendable {
  public var projectPath: String
  public var templates: [RemoteTemplateMetadata]

  public init(projectPath: String, templates: [RemoteTemplateMetadata]) {
    self.projectPath = projectPath
    self.templates = templates
  }
}
public struct RemoteTemplateContent: Codable, Equatable, Sendable {
  public var projectPath: String
  public var template: PromptTemplate

  public init(projectPath: String, template: PromptTemplate) {
    self.projectPath = projectPath
    self.template = template
  }
}
public struct AttachmentUploadDeclaration: Codable, Equatable, Sendable {
  public static let maximumFileBytes = 10 * 1024 * 1024
  public static let maximumFilesPerNode = 10

  public var name: String
  public var contentType: String
  public var size: Int
  public var sha256: String

  public init(name: String, contentType: String, size: Int, sha256: String) {
    self.name = name
    self.contentType = contentType
    self.size = size
    self.sha256 = sha256
  }

  public func validated() throws -> Self {
    guard Self.isSafeName(name), !contentType.isEmpty, contentType.utf8.count <= 128,
      (1...Self.maximumFileBytes).contains(size),
      sha256.count == 64, sha256.allSatisfy(\.isHexDigit)
    else { throw RemoteAssetError.invalidDeclaration }
    return self
  }

  public static func isSafeName(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128,
      value == URL(fileURLWithPath: value).lastPathComponent,
      !value.contains("/"), !value.contains("\\"),
      value != ".", value != "..",
      !value.contains(":"), value.last != ".", value.last != " ",
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return false }
    let stem = value.split(separator: ".", maxSplits: 1).first.map(String.init) ?? value
    let reserved = Set([
      "CON", "PRN", "AUX", "NUL",
      "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
      "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ])
    return !reserved.contains(stem.uppercased())
  }
}
public struct AttachmentUploadTicket: Codable, Equatable, Sendable {
  public var transferID: UUID
  public var maximumChunkBytes: Int
  public var expiresAt: Date

  public init(transferID: UUID, maximumChunkBytes: Int, expiresAt: Date) {
    self.transferID = transferID
    self.maximumChunkBytes = maximumChunkBytes
    self.expiresAt = expiresAt
  }
}
public struct AttachmentUploadProgress: Codable, Equatable, Sendable {
  public var transferID: UUID
  public var nextOffset: Int

  public init(transferID: UUID, nextOffset: Int) {
    self.transferID = transferID
    self.nextOffset = nextOffset
  }
}
public struct AttachmentFinalization: Equatable, Sendable {
  public var deliveryID: UUID
  public var attachment: PromptAttachment

  public init(deliveryID: UUID, attachment: PromptAttachment) {
    self.deliveryID = deliveryID
    self.attachment = attachment
  }
}
public struct AttachmentTransferContext: Equatable, Sendable {
  public var projectPath: String
  public var metadata: ProjectMetadata
  public var nodeID: UUID

  public init(projectPath: String, metadata: ProjectMetadata, nodeID: UUID) {
    self.projectPath = projectPath
    self.metadata = metadata
    self.nodeID = nodeID
  }
}
public struct RemoteAssetUsageSnapshot: Equatable, Sendable {
  public var activeTransfers: Int
  public var declaredBytes: Int
  public var bufferedBytes: Int
  public var pendingDeliveries: Int
  public var finalizedDrafts: Int
  public var finalizedAttachments: Int
  public var finalizedBytes: Int
  public var pendingDraftCleanups: Int

  public init(
    activeTransfers: Int, declaredBytes: Int, bufferedBytes: Int, pendingDeliveries: Int,
    finalizedDrafts: Int = 0, finalizedAttachments: Int = 0, finalizedBytes: Int = 0,
    pendingDraftCleanups: Int = 0
  ) {
    self.activeTransfers = activeTransfers
    self.declaredBytes = declaredBytes
    self.bufferedBytes = bufferedBytes
    self.pendingDeliveries = pendingDeliveries
    self.finalizedDrafts = finalizedDrafts
    self.finalizedAttachments = finalizedAttachments
    self.finalizedBytes = finalizedBytes
    self.pendingDraftCleanups = pendingDraftCleanups
  }
}
public enum RemoteAssetError: String, Error, Codable, Equatable, Sendable {
  case unauthorized
  case unsupported
  case invalidBounds
  case invalidDeclaration
  case tooManyAttachments
  case resourceExhausted
  case unknownTransfer
  case expiredTransfer
  case invalidOffset
  case oversized
  case hashMismatch
  case invalidReference
  case ambiguousTemplate
  case missing
  case unsafeFile
  case transportFailure

  public var message: String {
    switch self {
    case .unauthorized: return "remote asset access is not authorized for this connection"
    case .unsupported: return "remote assets are not supported for this project"
    case .invalidBounds: return "remote asset bounds are outside the supported range"
    case .invalidDeclaration: return "attachment declaration is invalid"
    case .tooManyAttachments: return "the node has reached the attachment count limit"
    case .resourceExhausted: return "remote asset transfer capacity is exhausted"
    case .unknownTransfer: return "attachment transfer is unknown"
    case .expiredTransfer: return "attachment transfer has expired"
    case .invalidOffset: return "attachment chunks must be contiguous and ordered"
    case .oversized: return "remote asset data exceeds the supported bound"
    case .hashMismatch: return "attachment integrity verification failed"
    case .invalidReference: return "attachment reference is invalid"
    case .ambiguousTemplate: return "the requested template identity is ambiguous"
    case .missing: return "the requested remote asset is missing"
    case .unsafeFile: return "the requested remote asset is not a safe regular file"
    case .transportFailure: return "the authoritative project host could not be reached"
    }
  }
}
public enum RemoteAssetDigest {
  public static func sha256Hex(_ data: Data) -> String {
    GraphcodeSHA256.digest(data).map { String(format: "%02x", $0) }.joined()
  }
}
