import Foundation
import XCTest

@testable import GraphcodeKit

final class RemoteAssetTests: XCTestCase {
  private actor Fixture {
    var documents: [String: [(origin: TemplateOrigin, fileName: String, content: String)]] = [:]
    var staged: [String: Data] = [:]
    var discarded: [String] = []

    func setDocuments(
      _ value: [(origin: TemplateOrigin, fileName: String, content: String)], for path: String
    ) {
      documents[path] = value
    }

    func readDocuments(_ path: String) -> [(TemplateOrigin, String, String)] {
      documents[path] ?? []
    }

    func stage(path: String, nodeID: UUID, name: String, data: Data) -> String {
      staged["\(path)|\(nodeID)|\(name)"] = data
      return "/synthetic/\(nodeID)/\(name)"
    }

    func discard(path: String, nodeID: UUID) {
      discarded.append("\(path)|\(nodeID)")
    }

    func stagedData(path: String, nodeID: UUID, name: String) -> Data? {
      staged["\(path)|\(nodeID)|\(name)"]
    }

    func replaceStaged(path: String, nodeID: UUID, name: String, data: Data) {
      staged["\(path)|\(nodeID)|\(name)"] = data
    }

    func resolve(path: String, nodeID: UUID, name: String, size: Int, sha256: String) throws
      -> String
    {
      guard let data = staged["\(path)|\(nodeID)|\(name)"], data.count == size,
        RemoteAssetDigest.sha256Hex(data) == sha256
      else { throw RemoteAssetError.hashMismatch }
      return "/synthetic/\(nodeID)/\(name)"
    }

    func retain(path: String, nodeID: UUID, names: Set<String>) {
      staged = staged.filter { key, _ in
        let prefix = "\(path)|\(nodeID)|"
        guard key.hasPrefix(prefix) else { return true }
        return names.contains(String(key.dropFirst(prefix.count)))
      }
    }
  }

  private func store(
    fixture: Fixture, now: @escaping @Sendable () -> Date = { Date() }
  ) -> RemoteAssetStore {
    RemoteAssetStore(
      transport: RemoteAssetHostTransport(
        templateDocuments: { path, _, _ in await fixture.readDocuments(path) },
        stageAttachment: { path, _, nodeID, name, data in
          await fixture.stage(path: path, nodeID: nodeID, name: name, data: data)
        },
        discardAttachments: { path, _, nodeID in
          await fixture.discard(path: path, nodeID: nodeID)
        },
        resolveAttachment: { path, _, nodeID, name, size, sha256 in
          try await fixture.resolve(
            path: path, nodeID: nodeID, name: name, size: size, sha256: sha256)
        },
        retainAttachments: { path, _, nodeID, names in
          await fixture.retain(path: path, nodeID: nodeID, names: names)
        }),
      authenticationKey: Data(repeating: 0x41, count: 32),
      now: now)
  }

  private func declaration(name: String = "image-1.png", data: Data) -> AttachmentUploadDeclaration
  {
    AttachmentUploadDeclaration(
      name: name, contentType: "image/png", size: data.count,
      sha256: GraphcodeSHA256.digest(data).map { String(format: "%02x", $0) }.joined())
  }

  func testLocalSSHAndCodespaceUseDistinctAuthoritativeOwnership() async throws {
    let fixture = Fixture()
    let store = store(fixture: fixture)
    let owner = UUID()
    let nodeID = UUID()
    let data = Data("same bytes".utf8)
    let projects: [(String, ProjectMetadata)] = [
      ("C:\\same\\repo", .local),
      ("C:\\same\\repo", .ssh),
      ("C:\\same\\repo", .codespace),
    ]

    var references: Set<String> = []
    for (path, metadata) in projects {
      let ticket = try await store.beginUpload(
        owner: owner, projectPath: path, metadata: metadata, nodeID: nodeID,
        declaration: declaration(data: data), existingCount: 0
      ).get()
      _ = try await store.append(
        owner: owner, transferID: ticket.transferID, offset: 0, data: data
      ).get()
      let attachment = try await store.finalize(
        owner: owner, transferID: ticket.transferID
      ).get()
      references.insert(attachment.path)
      XCTAssertFalse(attachment.path.contains(path))
      let staged = await fixture.stagedData(path: path, nodeID: nodeID, name: "image-1.png")
      XCTAssertEqual(staged, data)
    }
    XCTAssertEqual(references.count, projects.count)
  }

  func testUploadRejectsOverlapGapOversizeAndCrossClient() async throws {
    let fixture = Fixture()
    let store = store(fixture: fixture)
    let owner = UUID()
    let data = Data(repeating: 0x7a, count: 8)
    let ticket = try await store.beginUpload(
      owner: owner, projectPath: "C:\\fixture", metadata: .local, nodeID: UUID(),
      declaration: declaration(data: data), existingCount: 0
    ).get()

    let crossClient = await store.append(
      owner: UUID(), transferID: ticket.transferID, offset: 0, data: data)
    XCTAssertThrowsError(try crossClient.get())
    let gap = await store.append(
      owner: owner, transferID: ticket.transferID, offset: 1, data: data)
    XCTAssertThrowsError(try gap.get())
    _ = try await store.append(
      owner: owner, transferID: ticket.transferID, offset: 0, data: data.prefix(4)
    ).get()
    let overlap = await store.append(
      owner: owner, transferID: ticket.transferID, offset: 3, data: Data(data.suffix(4)))
    XCTAssertThrowsError(try overlap.get())
    let oversized = await store.append(
      owner: owner, transferID: ticket.transferID, offset: 4,
      data: Data(repeating: 0, count: RemoteAssetStore.maximumChunkBytes + 1))
    XCTAssertThrowsError(try oversized.get())
  }

  func testFinalizeRequiresCompleteMatchingHashAndCannotReplay() async throws {
    let fixture = Fixture()
    let store = store(fixture: fixture)
    let owner = UUID()
    let data = Data("payload".utf8)
    var wrong = declaration(data: data)
    wrong.sha256 = String(repeating: "0", count: 64)
    let ticket = try await store.beginUpload(
      owner: owner, projectPath: "C:\\fixture", metadata: .local, nodeID: UUID(),
      declaration: wrong, existingCount: 0
    ).get()
    _ = try await store.append(
      owner: owner, transferID: ticket.transferID, offset: 0, data: data
    ).get()
    let mismatch = await store.finalize(owner: owner, transferID: ticket.transferID)
    XCTAssertThrowsError(try mismatch.get())
    let replay = await store.finalize(owner: owner, transferID: ticket.transferID)
    XCTAssertThrowsError(try replay.get())
  }

  func testDisconnectAndExpiryInvalidateTransfers() async throws {
    final class Clock: @unchecked Sendable {
      private let lock = NSLock()
      private var value = Date(timeIntervalSince1970: 100)
      func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
      }
      func advance(_ interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
      }
    }
    let clock = Clock()
    let fixture = Fixture()
    let store = store(fixture: fixture, now: { clock.now() })
    let owner = UUID()
    let data = Data("x".utf8)
    let first = try await store.beginUpload(
      owner: owner, projectPath: "C:\\fixture", metadata: .local, nodeID: UUID(),
      declaration: declaration(data: data), existingCount: 0
    ).get()
    await store.disconnected(owner: owner)
    let disconnected = await store.append(
      owner: owner, transferID: first.transferID, offset: 0, data: data)
    XCTAssertThrowsError(try disconnected.get())

    let second = try await store.beginUpload(
      owner: owner, projectPath: "C:\\fixture", metadata: .local, nodeID: UUID(),
      declaration: declaration(data: data), existingCount: 0
    ).get()
    clock.advance(RemoteAssetStore.transferLifetime + 1)
    let expired = await store.append(
      owner: owner, transferID: second.transferID, offset: 0, data: data)
    XCTAssertThrowsError(try expired.get())
  }

  func testOpaqueReferenceBindsProjectNodeAndName() async throws {
    let fixture = Fixture()
    let store = store(fixture: fixture)
    let owner = UUID()
    let nodeID = UUID()
    let data = Data("payload".utf8)
    let ticket = try await store.beginUpload(
      owner: owner, projectPath: "ssh://fixture/repo", metadata: .ssh, nodeID: nodeID,
      declaration: declaration(data: data), existingCount: 0
    ).get()
    _ = try await store.append(
      owner: owner, transferID: ticket.transferID, offset: 0, data: data
    ).get()
    let attachment = try await store.finalize(owner: owner, transferID: ticket.transferID).get()

    _ = try await store.validate(
      [attachment], projectPath: "ssh://fixture/repo", metadata: .ssh, nodeID: nodeID
    ).get()
    let crossProject = await store.validate(
      [attachment], projectPath: "codespace://fixture/repo", metadata: .ssh, nodeID: nodeID)
    XCTAssertThrowsError(try crossProject.get())
    let crossClassification = await store.validate(
      [attachment], projectPath: "ssh://fixture/repo", metadata: .codespace, nodeID: nodeID)
    XCTAssertThrowsError(try crossClassification.get())
    let crossNode = await store.validate(
      [attachment], projectPath: "ssh://fixture/repo", metadata: .ssh, nodeID: UUID())
    XCTAssertThrowsError(try crossNode.get())
    let tampered = PromptAttachment(path: attachment.path + "x", name: attachment.name)
    let tamperedResult = await store.validate(
      [tampered], projectPath: "ssh://fixture/repo", metadata: .ssh, nodeID: nodeID)
    XCTAssertThrowsError(try tamperedResult.get())
  }

  func testTemplateListAndReadAreBoundedAndPathPrivate() async throws {
    let fixture = Fixture()
    let projectPath = "ssh://fixture/private/repo"
    let template = PromptTemplate(name: "Review", body: "Inspect the change")
    await fixture.setDocuments(
      [
        (
          .project(projectPath), "review.md",
          TemplateFileCodec.encode(template)
        )
      ], for: projectPath)
    let store = store(fixture: fixture)
    let list = try await store.listTemplates(
      owner: UUID(), projectPath: projectPath, metadata: .ssh,
      query: RemoteTemplateListQuery(maxCount: 1, maxBytes: 4096)
    ).get()
    XCTAssertEqual(list.templates.map(\.name), ["Review"])
    let encodedList = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
    XCTAssertFalse(encodedList.contains("/private/repo/.graphcode"))

    let content = try await store.readTemplate(
      owner: UUID(), projectPath: projectPath, metadata: .ssh,
      query: RemoteTemplateReadQuery(templateID: template.id, maxBytes: 4096)
    ).get()
    XCTAssertEqual(content.template.body, "Inspect the change")
    XCTAssertThrowsError(
      try RemoteTemplateReadQuery(templateID: template.id, maxBytes: 0).validated())
  }

  func testNamesRejectTraversalSeparatorsAndReservedDevices() {
    for name in [
      "../x.png", "a/b.png", "a\\b.png", "C:x.png", "NUL.png", ".", "..", "image.png.",
      "image.png ", "image\u{0007}.png",
    ] {
      XCTAssertFalse(AttachmentUploadDeclaration.isSafeName(name), name)
    }
    XCTAssertTrue(AttachmentUploadDeclaration.isSafeName("image-1.png"))
  }

  func testRemoteArgumentsQuoteShellMetacharactersExactly() {
    let name = "image-';$(touch pwn).png"
    XCTAssertTrue(AttachmentUploadDeclaration.isSafeName(name))
    XCTAssertEqual(
      RemoteProjectLocation.shellQuoted(name),
      "'image-'\\'';$(touch pwn).png'")
  }

  func testChunkEnvelopeStaysBelowV2FrameLimit() throws {
    let command = DaemonCommand.uploadAttachmentChunk(
      transferID: UUID(), offset: 0,
      data: Data(repeating: 0xff, count: RemoteAssetStore.maximumChunkBytes))
    let frame = try JSONEncoder().encode(DaemonWireEnvelope.request(id: UUID(), command: command))
    XCTAssertLessThanOrEqual(frame.count, FramedMessageIO.v2MaxPayloadBytes)
  }

  func testRemoteAssetProtocolCasesRoundTripAdditively() throws {
    let transferID = UUID()
    let nodeID = UUID()
    let commands: [DaemonCommand] = [
      .listTemplates(projectPath: "C:\\fixture", query: RemoteTemplateListQuery()),
      .readTemplate(
        projectPath: "C:\\fixture", query: RemoteTemplateReadQuery(templateID: UUID())),
      .beginAttachmentUpload(
        projectPath: "C:\\fixture", nodeID: nodeID,
        declaration: declaration(data: Data("payload".utf8))),
      .uploadAttachmentChunk(
        transferID: transferID, offset: 0, data: Data("payload".utf8)),
      .finalizeAttachmentUpload(transferID: transferID),
      .cancelAttachmentUpload(transferID: transferID),
      .discardStagedAttachments(projectPath: "C:\\fixture", nodeID: nodeID),
    ]
    for command in commands {
      XCTAssertEqual(
        try JSONDecoder().decode(
          DaemonCommand.self, from: JSONEncoder().encode(command)),
        command)
    }
  }

  func testGraphAndReplayContainReferenceButNeverAttachmentBytes() async throws {
    let fixture = Fixture()
    let store = store(fixture: fixture)
    let owner = UUID()
    let nodeID = UUID()
    let secretBytes = Data("attachment-secret-body".utf8)
    let ticket = try await store.beginUpload(
      owner: owner, projectPath: "C:\\fixture", metadata: .local, nodeID: nodeID,
      declaration: declaration(data: secretBytes), existingCount: 0
    ).get()
    _ = try await store.append(
      owner: owner, transferID: ticket.transferID, offset: 0, data: secretBytes
    ).get()
    let attachment = try await store.finalize(owner: owner, transferID: ticket.transferID).get()
    let node = LoopNode(
      id: nodeID, title: "Synthetic", loopType: .turnBased,
      firstInstruction: "inspect [image #1]", attachments: [attachment])
    let graph = LoopGraph(
      project: ProjectRef(path: "C:\\fixture", name: "fixture"), nodes: [node])
    var replay = DaemonReplayBuffer()
    replay.append(sequence: 1, event: .graphChanged(graph))
    let encodedGraph = String(decoding: try JSONEncoder().encode(graph), as: UTF8.self)
    let encodedReplay = String(
      decoding: try JSONEncoder().encode(try replay.replay(after: 0)), as: UTF8.self)
    XCTAssertFalse(encodedGraph.contains("attachment-secret-body"))
    XCTAssertFalse(encodedReplay.contains("attachment-secret-body"))
    XCTAssertTrue(encodedGraph.contains("graphcode-attachment:v1:"))
  }

  func testLauncherResolutionUsesExactOpaqueReferencePath() async throws {
    let fixture = Fixture()
    let store = store(fixture: fixture)
    let owner = UUID()
    let nodeID = UUID()
    let data = Data("payload".utf8)
    let projectPath = "codespace://fixture/repo"
    let ticket = try await store.beginUpload(
      owner: owner, projectPath: projectPath, metadata: .codespace, nodeID: nodeID,
      declaration: declaration(data: data), existingCount: 0
    ).get()
    _ = try await store.append(
      owner: owner, transferID: ticket.transferID, offset: 0, data: data
    ).get()
    let attachment = try await store.finalize(owner: owner, transferID: ticket.transferID).get()
    let path = try await store.resolvedPath(
      for: attachment, projectPath: projectPath, nodeID: nodeID, metadata: .codespace
    ).get()
    let prompt = PromptAttachments.resolving(
      "open [image #1]",
      attachments: [
        PromptAttachment(id: attachment.id, path: path, name: attachment.name)
      ])
    XCTAssertEqual(prompt, "open \(path)")
    XCTAssertFalse(path.contains("codespace://"))
  }

  func testLauncherResolutionRejectsStagedContentReplacement() async throws {
    let fixture = Fixture()
    let store = store(fixture: fixture)
    let owner = UUID()
    let nodeID = UUID()
    let projectPath = "ssh://fixture/repo"
    let data = Data("original".utf8)
    let ticket = try await store.beginUpload(
      owner: owner, projectPath: projectPath, metadata: .ssh, nodeID: nodeID,
      declaration: declaration(data: data), existingCount: 0
    ).get()
    _ = try await store.append(
      owner: owner, transferID: ticket.transferID, offset: 0, data: data
    ).get()
    let attachment = try await store.finalize(owner: owner, transferID: ticket.transferID).get()
    await fixture.replaceStaged(
      path: projectPath, nodeID: nodeID, name: attachment.fileName,
      data: Data("tampered".utf8))

    let result = await store.resolvedPath(
      for: attachment, projectPath: projectPath, nodeID: nodeID, metadata: .ssh)
    XCTAssertEqual(result, .failure(.hashMismatch))
  }

  func testRetainingDraftReferencesRemovesUnselectedStagedFiles() async throws {
    let fixture = Fixture()
    let store = store(fixture: fixture)
    let owner = UUID()
    let nodeID = UUID()
    let projectPath = "C:\\fixture"
    var attachments: [PromptAttachment] = []
    for name in ["image-1.png", "image-2.png"] {
      let data = Data(name.utf8)
      let ticket = try await store.beginUpload(
        owner: owner, projectPath: projectPath, metadata: .local, nodeID: nodeID,
        declaration: declaration(name: name, data: data), existingCount: attachments.count
      ).get()
      _ = try await store.append(
        owner: owner, transferID: ticket.transferID, offset: 0, data: data
      ).get()
      attachments.append(
        try await store.finalize(owner: owner, transferID: ticket.transferID).get())
    }

    _ = try await store.retainOnly(
      [attachments[1]], projectPath: projectPath, metadata: .local, nodeID: nodeID
    ).get()

    let removed = await fixture.stagedData(
      path: projectPath, nodeID: nodeID, name: "image-1.png")
    let retained = await fixture.stagedData(
      path: projectPath, nodeID: nodeID, name: "image-2.png")
    XCTAssertNil(removed)
    XCTAssertNotNil(retained)

    _ = try await store.retainOnly(
      [], projectPath: projectPath, metadata: .local, nodeID: nodeID
    ).get()
    let removedLast = await fixture.stagedData(
      path: projectPath, nodeID: nodeID, name: "image-2.png")
    XCTAssertNil(removedLast)
  }

  func testLocalTemplateReaderRejectsSymlinkAndHardlinkAliases() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("remote-assets-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    let project = base.appendingPathComponent("project", isDirectory: true)
    let projectTemplates = project.appendingPathComponent(".graphcode/templates", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: projectTemplates, withIntermediateDirectories: true)
    let safe = PromptTemplate(name: "Safe", body: "bounded")
    try TemplateFileCodec.encode(safe).write(
      to: projectTemplates.appendingPathComponent("safe.md"), atomically: true, encoding: .utf8)
    let outside = base.appendingPathComponent("outside.md")
    try TemplateFileCodec.encode(PromptTemplate(name: "Private", body: "do not read")).write(
      to: outside, atomically: true, encoding: .utf8)
    try FileManager.default.linkItem(
      at: outside, to: projectTemplates.appendingPathComponent("hardlink.md"))
    try? FileManager.default.createSymbolicLink(
      at: projectTemplates.appendingPathComponent("symlink.md"), withDestinationURL: outside)
    let storage = TemplateStorage(
      homeDirectory: home,
      projectDirectory: { _ in projectTemplates })

    let documents = try LocalRemoteAssetHost.templateDocuments(
      projectPath: project.path, maximumBytes: 4096, storage: storage)
    XCTAssertEqual(documents.map(\.fileName), ["safe.md"])
    XCTAssertFalse(documents.map(\.content).joined().contains("do not read"))
  }
}
