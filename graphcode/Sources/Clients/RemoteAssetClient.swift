import Dependencies
import Foundation
import GraphcodeKit

struct RemoteAssetClient: Sendable {
  var templates: @Sendable (_ projectPath: String) async throws -> [PromptTemplate]
  var upload:
    @Sendable (
      _ projectPath: String, _ nodeID: UUID, _ name: String, _ contentType: String, _ data: Data
    ) async throws -> PromptAttachment
  var discard: @Sendable (_ projectPath: String, _ nodeID: UUID) async -> Void
}
extension RemoteAssetClient: DependencyKey {
  static let liveValue = RemoteAssetClient(
    templates: { projectPath in
      try await Task.detached {
        let client = try DaemonSocketClient()
        let session = try client.v2Session()
        defer { session.close() }
        _ = try session.request(.openProject(path: projectPath))
        guard
          case .templateList(let list) = try session.request(
            .listTemplates(projectPath: projectPath, query: RemoteTemplateListQuery()))
        else { throw DaemonSocketClient.ClientError.malformedResponse }
        return try list.templates.compactMap { metadata in
          guard
            case .templateContent(let content) = try session.request(
              .readTemplate(
                projectPath: projectPath,
                query: RemoteTemplateReadQuery(templateID: metadata.id)))
          else { return nil }
          return content.template
        }
      }.value
    },
    upload: { projectPath, nodeID, name, contentType, data in
      let task = Task.detached {
        let client = try DaemonSocketClient()
        let session = try client.v2Session()
        defer { session.close() }
        var transferID: UUID?
        var finalized = false
        defer {
          if finalized, Task.isCancelled {
            _ = try? session.request(
              .discardStagedAttachments(projectPath: projectPath, nodeID: nodeID))
          } else if let transferID, !finalized {
            _ = try? session.request(.cancelAttachmentUpload(transferID: transferID))
          }
        }
        try Task.checkCancellation()
        _ = try session.request(.openProject(path: projectPath))
        let declaration = AttachmentUploadDeclaration(
          name: name, contentType: contentType, size: data.count,
          sha256: RemoteAssetDigest.sha256Hex(data))
        guard
          case .attachmentUploadBegan(let ticket) = try session.request(
            .beginAttachmentUpload(
              projectPath: projectPath, nodeID: nodeID, declaration: declaration))
        else { throw DaemonSocketClient.ClientError.malformedResponse }
        transferID = ticket.transferID
        try Task.checkCancellation()
        var offset = 0
        while offset < data.count {
          try Task.checkCancellation()
          let end = min(data.count, offset + ticket.maximumChunkBytes)
          let chunk = data.subdata(in: offset..<end)
          guard
            case .attachmentUploadProgress(let progress) = try session.request(
              .uploadAttachmentChunk(transferID: ticket.transferID, offset: offset, data: chunk)),
            progress.nextOffset == end
          else { throw DaemonSocketClient.ClientError.malformedResponse }
          offset = end
        }
        try Task.checkCancellation()
        guard
          case .attachmentStaged(let attachment) = try session.request(
            .finalizeAttachmentUpload(transferID: ticket.transferID))
        else { throw DaemonSocketClient.ClientError.malformedResponse }
        finalized = true
        try Task.checkCancellation()
        return attachment
      }
      return try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    },
    discard: { projectPath, nodeID in
      await Task.detached {
        guard let client = try? DaemonSocketClient(),
          let session = try? client.v2Session()
        else { return }
        defer { session.close() }
        _ = try? session.request(.openProject(path: projectPath))
        _ = try? session.request(
          .discardStagedAttachments(projectPath: projectPath, nodeID: nodeID))
      }.value
    })

  static let testValue = RemoteAssetClient(
    templates: { _ in [] },
    upload: { _, _, name, _, _ in
      PromptAttachment(path: "\(PromptAttachment.opaqueReferencePrefix)\(name)", name: name)
    },
    discard: { _, _ in })
}
extension DependencyValues {
  var remoteAssets: RemoteAssetClient {
    get { self[RemoteAssetClient.self] }
    set { self[RemoteAssetClient.self] = newValue }
  }
}
