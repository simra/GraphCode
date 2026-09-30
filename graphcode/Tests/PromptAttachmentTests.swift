import AppKit
import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// What happens to a picture between the New Node dialog and the agent.
///
/// The image itself never moves: `zmx` types a session's launch command into a PTY, so
/// the prompt is text on a line and a path is the only thing that can ride it. These are
/// the rules that make that path land where the human put the picture.
@Suite
struct PromptAttachmentTests {
  private static func attachment(_ path: String) -> PromptAttachment {
    PromptAttachment(id: UUID(), path: path)
  }

  @Test
  func aPlaceholderBecomesThePathWhereItStood() {
    let resolved = PromptAttachments.resolving(
      "compare [image #1] with the current header",
      attachments: [Self.attachment("/tmp/a.png")])
    #expect(resolved == "compare /tmp/a.png with the current header")
  }

  @Test
  func eachPlaceholderTakesItsOwnPath() {
    let resolved = PromptAttachments.resolving(
      "[image #2] is what [image #1] should look like",
      attachments: [Self.attachment("/tmp/a.png"), Self.attachment("/tmp/b.png")])
    #expect(resolved == "/tmp/b.png is what /tmp/a.png should look like")
  }

  @Test
  func animageTheTextNeverNamedIsStatedAtTheEnd() throws {
    // A human can delete the placeholder and keep the chip. The picture is still
    // attached, so the prompt still has to say where it is.
    let resolved = try #require(
      PromptAttachments.resolving(
        "make the header match", attachments: [Self.attachment("/tmp/a.png")]))
    #expect(resolved.hasPrefix("make the header match "))
    #expect(resolved.contains("An image for this task is at /tmp/a.png"))
  }

  @Test
  func aPromptThatIsOnlyAnImageIsStillAPrompt() throws {
    let resolved = try #require(
      PromptAttachments.resolving("", attachments: [Self.attachment("/tmp/a.png")]))
    #expect(resolved.hasPrefix("An image for this task is at /tmp/a.png"))
  }

  @Test
  func noAttachmentsLeavesTheTextExactlyAsWritten() {
    #expect(PromptAttachments.resolving("plain", attachments: []) == "plain")
    #expect(PromptAttachments.resolving(nil, attachments: []) == nil)
  }

  @Test
  func removingTheMiddleImageRenumbersTheOnesBehindIt() {
    // Otherwise `[image #3]` survives a two-image draft and resolves to nothing.
    let text = PromptAttachments.removing(
      attachment: 2, from: "a [image #1] b [image #2] c [image #3]", of: 3)
    #expect(text == "a [image #1] b c [image #2]")
  }

  @Test
  func aGoalCarriesThePathInsideTheConditionRatherThanAfterIt() throws {
    // `/goal` takes the rest of the line as its condition, so a path appended past the
    // predicate and the metric would become part of what an evaluator judges.
    let node = LoopNode(
      title: "Header", loopType: .goalBased,
      attachments: [Self.attachment("/tmp/a.png")],
      goal: GoalSpec(summary: "the header matches [image #1]", predicate: "swift test"),
      backend: .claudeCode)
    let prompt = try #require(node.sessionPrompt)
    let path = try #require(prompt.range(of: "/tmp/a.png"))
    let predicate = try #require(prompt.range(of: "The goal counts as met when"))
    #expect(path.lowerBound < predicate.lowerBound)
  }

  @Test
  func aSketchWhoseNoteIsOnlyAnImageOpensAnyway() throws {
    // A blank note means the session opens quiet — but an attached picture is itself
    // something to say, so this one has a prompt.
    let node = LoopNode(
      title: "Look", loopType: .sketch, firstInstruction: nil,
      attachments: [Self.attachment("/tmp/a.png")])
    let prompt = try #require(node.sessionPrompt)
    #expect(prompt.contains("/tmp/a.png"))
    #expect(LoopNode(title: "Look", loopType: .sketch).sessionPrompt == nil)
  }

  @Test
  func aTimedLoopKeepsItsDirectiveAndCarriesThePathIntoTheTask() throws {
    // The directive has to stay the first thing on the line or no schedule is armed
    // (issue #179); the path belongs inside the task it repeats.
    let node = LoopNode(
      title: "Watch", loopType: .timeBased,
      triggerPrompt: "/loop 1h check the banner against [image #1]",
      attachments: [Self.attachment("/tmp/a.png")])
    let prompt = try #require(node.sessionPrompt)
    #expect(prompt.hasPrefix("/loop 1h "))
    #expect(prompt.contains("/tmp/a.png"))
  }

  @Test
  func aPathVerifyingBackendIsGrantedTheDirectoryTheImageIsIn() {
    // Codex and Copilot check paths, and a prompt naming a file the session is denied
    // reads as the agent ignoring its instructions.
    let node = LoopNode(
      title: "Header", loopType: .goalBased,
      attachments: [Self.attachment("/tmp/shots/a.png")],
      goal: GoalSpec(summary: "match [image #1]"), backend: .codex)
    let paths = ZmxSessionLauncher.workspacePaths(forNode: node, projectPath: "/tmp/project")
    #expect(paths.contains("/tmp/shots"))
  }

  @Test
  func aDraftCarriesItsAttachmentsOntoTheNodeAndOverTheWire() throws {
    let draft = NodeDraft(
      title: "Header", loopType: .sketch, firstInstruction: "look at [image #1]",
      attachments: [Self.attachment("/tmp/a.png")])
    #expect(draft.makeNode().attachments.map(\.path) == ["/tmp/a.png"])
    let decoded = try JSONDecoder().decode(
      NodeDraft.self, from: try JSONEncoder().encode(draft))
    #expect(decoded.attachments == draft.attachments)
  }

  @Test
  func aDraftFromACLIThatPredatesAttachmentsDecodesWithNone() throws {
    // Loops keep creating nodes with whatever `graphcode` binary they already have.
    let json = #"{"title":"Header","loopType":"sketch"}"#
    let decoded = try JSONDecoder().decode(NodeDraft.self, from: Data(json.utf8))
    #expect(decoded.attachments.isEmpty)
  }
}

/// Reading a pasteboard, and the one judgement call in it.
@Suite
struct DraftImageImportTests {
  private static func pasteboard() -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("graphcode.test.\(UUID().uuidString)"))
    board.clearContents()
    return board
  }

  private static let onePixelPNG = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )!

  @Test
  func aScreenshotOnTheBoardIsTakenAsAnImage() throws {
    let board = Self.pasteboard()
    board.setData(Self.onePixelPNG, forType: .png)
    let payload = try #require(DraftImageImport.payload(on: board))
    #expect(payload.fileExtension == "png")
    #expect(payload.data == Self.onePixelPNG)
  }

  @Test
  func aBoardCarryingWordsAsWellAsPixelsIsReadAsWords() {
    // Copying out of a rich-text editor puts a rendering of the selection on the board
    // beside the text. Swallowing that ⌘V would lose a paste the human meant; missing
    // an image paste costs nothing, because the same picture can be dragged in.
    let board = Self.pasteboard()
    board.setData(Self.onePixelPNG, forType: .png)
    board.setString("some words", forType: .string)
    #expect(DraftImageImport.payload(on: board) == nil)
  }

  @Test
  func aCopiedImageFileWinsEvenWithTextBesideIt() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-test-\(UUID().uuidString).png")
    try Self.onePixelPNG.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let board = Self.pasteboard()
    board.writeObjects([url as NSURL])
    board.setString(url.path, forType: .string)
    let payload = try #require(DraftImageImport.payload(on: board))
    #expect(payload.data == Self.onePixelPNG)
  }

  @Test
  func aCopiedTextFileIsNotAnImage() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-test-\(UUID().uuidString).txt")
    try Data("hello".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let board = Self.pasteboard()
    board.writeObjects([url as NSURL])
    #expect(DraftImageImport.payload(on: board) == nil)
  }

  @Test
  func anEmptyBoardLeavesPasteAlone() {
    #expect(DraftImageImport.payload(on: Self.pasteboard()) == nil)
  }
}

/// The dialog's half: a pasted image is staged on the project host, its placeholder lands
/// in the field the human is filling in, and the draft carries the opaque reference.
@Suite
struct DraftAttachmentReducerTests {
  private static let project = ProjectRef(
    path: "/tmp/graphcode-attachment-test", name: "t", metadata: .local)

  private static let payload = DraftImageImport.Payload(
    data: Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!, fileExtension: "png")

  private static func store(
    _ project: ProjectRef = project, loopType: LoopType = .sketch, note: String = "",
    remoteAssets: RemoteAssetClient = .testValue
  ) -> TestStore<ProjectFeature.State, ProjectFeature.Action> {
    var state = ProjectFeature.State(graph: LoopGraph(project: project))
    state.draftLoopType = loopType
    state.draftSketchNote = note
    let store = TestStore(initialState: state) {
      ProjectFeature()
    } withDependencies: {
      $0.remoteAssets = remoteAssets
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  @MainActor
  func apastedImageIsStagedAndStandsInTheBriefAsAPlaceholder() async throws {
    let store = Self.store(note: "match this")

    await store.send(.draftAttachment(.imageArrived(Self.payload))) {
      $0.draftAttachments.taken = 1
      $0.draftAttachments.notice = "Uploading image…"
    }
    await store.receive(\.draftAttachment.uploadFinished)
    let reference = try #require(store.state.draftAttachments.items.first?.path)
    #expect(reference.hasPrefix(PromptAttachment.opaqueReferencePrefix))
    #expect(store.state.draftSketchNote == "match this [image #1]")
    // The draft is what crosses the wire, and the node's prompt is composed from it.
    #expect(store.state.draft.attachments.map(\.path) == [reference])
  }

  @Test
  @MainActor
  func aSecondImageGetsADistinctOpaqueReference() async {
    let store = Self.store()

    await store.send(.draftAttachment(.imageArrived(Self.payload)))
    await store.receive(\.draftAttachment.uploadFinished)
    await store.send(.draftAttachment(.imageArrived(Self.payload)))
    await store.receive(\.draftAttachment.uploadFinished)
    let references = store.state.draftAttachments.items.map(\.path)
    #expect(references.count == 2)
    #expect(Set(references).count == 2)
    #expect(store.state.draftSketchNote == "[image #1] [image #2]")
  }

  @Test
  @MainActor
  func identicalLookingRemoteProjectsUseTheirAuthoritativeClassification() async {
    let path = Self.project.path
    for metadata in [ProjectMetadata.ssh, .codespace] {
      let uploadedProject = LockIsolated<String?>(nil)
      let remoteAssets = RemoteAssetClient(
        templates: { _ in [] },
        upload: { projectPath, _, name, _, _ in
          uploadedProject.setValue(projectPath)
          return PromptAttachment(
            path: "\(PromptAttachment.opaqueReferencePrefix)\(metadata.location.rawValue)-\(name)",
            name: name)
        },
        discard: { _, _ in })
      let store = Self.store(
        ProjectRef(path: path, name: "remote", metadata: metadata),
        remoteAssets: remoteAssets)

      await store.send(.draftAttachment(.imageArrived(Self.payload)))
      await store.receive(\.draftAttachment.uploadFinished)

      #expect(uploadedProject.value == path)
      #expect(store.state.draftAttachments.items.count == 1)
      #expect(
        !FileManager.default.fileExists(
          atPath: NodeMemory.attachmentsDirectory(
            forProjectPath: path, nodeID: store.state.draftID
          ).path))
    }
  }

  @Test
  @MainActor
  func removingAChipTakesItsReferenceAndItsPlaceholder() async throws {
    let store = Self.store()

    await store.send(.draftAttachment(.imageArrived(Self.payload)))
    await store.receive(\.draftAttachment.uploadFinished)
    await store.send(.draftAttachment(.imageArrived(Self.payload)))
    await store.receive(\.draftAttachment.uploadFinished)
    let first = try #require(store.state.draftAttachments.items.first)
    await store.send(.draftAttachment(.removed(first.id)))

    #expect(store.state.draftAttachments.items.count == 1)
    // Renumbered, so the placeholder left behind still resolves.
    #expect(store.state.draftSketchNote == "[image #1]")
  }

  @Test
  @MainActor
  func theNextPasteAfterARemovalStillGetsAReferenceOfItsOwn() async throws {
    let store = Self.store()

    await store.send(.draftAttachment(.imageArrived(Self.payload)))
    await store.receive(\.draftAttachment.uploadFinished)
    await store.send(.draftAttachment(.imageArrived(Self.payload)))
    await store.receive(\.draftAttachment.uploadFinished)
    let first = try #require(store.state.draftAttachments.items.first)
    await store.send(.draftAttachment(.removed(first.id)))
    let survivor = try #require(store.state.draftAttachments.items.first?.path)
    await store.send(.draftAttachment(.imageArrived(Self.payload)))
    await store.receive(\.draftAttachment.uploadFinished)

    #expect(store.state.draftAttachments.items.map(\.path).contains(survivor))
    #expect(Set(store.state.draftAttachments.items.map(\.path)).count == 2)
  }

  @Test
  @MainActor
  func cancellingTheDialogDiscardsTheStagedDraft() async throws {
    let discardedNode = LockIsolated<UUID?>(nil)
    let remoteAssets = RemoteAssetClient(
      templates: { _ in [] },
      upload: RemoteAssetClient.testValue.upload,
      discard: { _, nodeID in discardedNode.setValue(nodeID) })
    let store = Self.store(remoteAssets: remoteAssets)
    let nodeID = store.state.draftID
    await store.send(.draftAttachment(.imageArrived(Self.payload)))
    await store.receive(\.draftAttachment.uploadFinished)

    await store.send(.cancelNewNodeForm) {
      $0.showingNewNodeForm = false
      $0.draftAttachments = ProjectFeature.DraftAttachments()
    }
    await store.finish()
    #expect(discardedNode.value == nodeID)
  }

  @Test
  @MainActor
  func aLoopOnAnotherMachineSaysSoRatherThanNamingAFileThatHostNeverSaw() async {
    // Missing authoritative metadata fails closed rather than guessing from the URI.
    let remote = ProjectRef(path: "ssh://box/~/work/repo", name: "repo")
    let store = Self.store(remote)

    await store.send(.draftAttachment(.imageArrived(Self.payload))) {
      $0.draftAttachments.notice =
        "Images can't be attached because this project did not advertise support."
    }
    #expect(store.state.draftAttachments.items.isEmpty)
  }

  @Test
  @MainActor
  func aCompositeHasNoPromptForAPathToTravelIn() async {
    let store = Self.store(loopType: .composite)

    await store.send(.draftAttachment(.imageArrived(Self.payload)))
    #expect(store.state.draftAttachments.items.isEmpty)
  }
}
