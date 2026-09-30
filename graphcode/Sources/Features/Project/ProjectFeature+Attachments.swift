import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The New Node dialog's images: what the draft holds, and what a paste or a drop does
/// to it.
///
/// Its own file for the reason `AppFeature`'s helpers have one — `ProjectFeature.swift`
/// sits at swiftlint's file and type-body budgets, and a concern that arrives whole is
/// easier to read whole.
extension ProjectFeature {
  /// Images attached to the brief field, already staged on the authoritative project
  /// host under the draft's own id. Each one put an `[image #N]` placeholder into the
  /// brief; the daemon resolves its opaque reference before the prompt is composed.
  struct DraftAttachments: Equatable {
    var items: [PromptAttachment] = []
    /// How many this draft has ever taken, which is what names their files. Position
    /// would re-use a name: remove the second of three and the next paste is number
    /// three again, landing on a file that is still attached.
    var taken = 0
    /// Why the last paste or drop did nothing — a remote graph, or a file too big.
    /// Shown beside the field and cleared by the next one that works.
    var notice: String?
  }

  enum DraftAttachmentAction: Equatable {
    /// An image arrived on the brief field — pasted over ⌘V or dropped onto it. Carries
    /// the decoded bytes because a pasteboard cannot be read from an effect: its
    /// contents belong to the moment of the keystroke.
    case imageArrived(DraftImageImport.Payload)
    case uploadFinished(number: Int, attachment: PromptAttachment?, error: String?)
    case removed(UUID)
    /// A drop that yielded nothing graphcode could write down.
    case rejected(String)
  }

  func draftAttachment(
    _ state: inout State, _ action: DraftAttachmentAction
  ) -> Effect<Action> {
    switch action {
    case .imageArrived(let payload): return attachDraftImage(&state, payload)
    case .uploadFinished(let number, let attachment, let error):
      guard let attachment else {
        state.draftAttachments.notice = error ?? "Couldn't save that image."
        return .none
      }
      state.draftAttachments.items.append(attachment)
      let placeholder = PromptAttachments.token(state.draftAttachments.items.count)
      let brief = state.currentBriefText
      state.setBriefText(brief.isEmpty ? placeholder : brief + " " + placeholder)
      state.draftAttachments.notice = nil
      state.draftAttachments.taken = max(state.draftAttachments.taken, number)
      return .none
    case .removed(let id): return removeDraftAttachment(&state, id)
    case .rejected(let reason):
      state.draftAttachments.notice = reason
      return .none
    }
  }

  /// Stages a pasted or dropped image and puts its placeholder in the brief.
  func attachDraftImage(
    _ state: inout State, _ payload: DraftImageImport.Payload
  ) -> Effect<Action> {
    // A composite never opens a session, so it has no prompt for a path to travel in —
    // and no prose field for the placeholder to land in either.
    guard state.draftLoopType != .composite else { return .none }
    guard state.draftAttachments.notice != "Uploading image…" else { return .none }
    guard state.draftAttachments.items.count < AttachmentUploadDeclaration.maximumFilesPerNode
    else {
      state.draftAttachments.notice = "A loop can have at most 10 images."
      return .none
    }
    let project = state.graph.project
    guard project.metadata?.capabilities.attachments == true else {
      state.draftAttachments.notice =
        "Images can't be attached because this project did not advertise support."
      return .none
    }
    let projectPath = project.path
    let number = state.draftAttachments.taken + 1
    state.draftAttachments.taken = number
    state.draftAttachments.notice = "Uploading image…"
    let nodeID = state.draftID
    let name = "image-\(number).\(payload.fileExtension)"
    let contentType = "image/\(payload.fileExtension == "jpg" ? "jpeg" : payload.fileExtension)"
    return .run { [remoteAssets] send in
      do {
        let attachment = try await remoteAssets.upload(
          projectPath, nodeID, name, contentType, payload.data)
        await send(
          .draftAttachment(
            .uploadFinished(number: number, attachment: attachment, error: nil)))
      } catch {
        await send(
          .draftAttachment(
            .uploadFinished(
              number: number, attachment: nil,
              error: "Couldn't stage that image on the project host.")))
      }
    }
    .cancellable(id: CancelID.attachmentUpload, cancelInFlight: false)
  }

  /// Takes the chip, the file, and the placeholder — and renumbers the placeholders
  /// after it, so removing the middle of three doesn't leave one pointing at nothing.
  func removeDraftAttachment(_ state: inout State, _ id: UUID) -> Effect<Action> {
    guard state.graph.project.metadata?.capabilities.attachments == true else {
      state.draftAttachments.notice =
        "Images can't be changed because this project did not advertise support."
      return .none
    }
    guard let index = state.draftAttachments.items.firstIndex(where: { $0.id == id })
    else { return .none }
    let total = state.draftAttachments.items.count
    let removed = state.draftAttachments.items.remove(at: index)
    _ = removed
    state.setBriefText(
      PromptAttachments.removing(
        attachment: index + 1, from: state.currentBriefText, of: total))
    state.draftAttachments.notice = nil
    return .none
  }

  /// Closing the dialog without creating anything. The draft's id is a node id nothing
  /// will now create, so its images have no other owner to outlive. A created node's are
  /// left alone: `NodeMemory.remove` takes them when the node itself goes.
  func cancelNodeForm(_ state: inout State) -> Effect<Action> {
    state.showingNewNodeForm = false
    let projectPath = state.graph.project.path
    let nodeID = state.draftID
    state.draftAttachments = DraftAttachments()
    return .concatenate(
      .cancel(id: CancelID.attachmentUpload),
      .cancel(id: CancelID.templateWatch),
      .run { [remoteAssets] _ in await remoteAssets.discard(projectPath, nodeID) })
  }
}
