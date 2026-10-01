import Foundation
import XCTest

@testable import GraphcodeKit

#if os(Windows)
  import func WinSDK.CreateHardLinkW
#endif

private actor RemoteStageGate {
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?

  func suspend() async {
    started = true
    await withCheckedContinuation { continuation = $0 }
  }

  func hasStarted() -> Bool {
    started
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private final class RemoteAssetTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

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

private final class RemoteAssetPersistenceFailure: @unchecked Sendable {
  private let lock = NSLock()
  private var failing = false

  func setFailing(_ value: Bool) {
    lock.withLock { failing = value }
  }

  func check() throws {
    if lock.withLock({ failing }) {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}

private final class RemoteAssetTestConnection: @unchecked Sendable, DaemonConnection {
  let id = UUID()
  let endpoint: DaemonEndpoint = .namedPipe("\\\\.\\pipe\\graphcode-remote-assets-test")
  let authenticatedPeerProcessID: UInt64?
  private let lock = NSLock()
  private var frames: [Data] = []

  init(peerProcessID: UInt64 = UInt64.random(in: 1...UInt64.max)) {
    authenticatedPeerProcessID = peerProcessID
  }

  func receiveFrame() async throws -> Data { Data() }
  func sendFrame(_ data: Data) async throws {
    lock.withLock { frames.append(data) }
  }
  func close() async throws {}

  func sentFrames() -> [Data] {
    lock.lock()
    defer { lock.unlock() }
    return frames
  }
}

private actor RemoteAssetLaunchRecorder {
  private var nodes: [LoopNode] = []

  func record(_ node: LoopNode) {
    nodes.append(node)
  }

  func values() -> [LoopNode] {
    nodes
  }

  func clear() {
    nodes.removeAll()
  }
}

final class RemoteAssetTests: XCTestCase {
  private actor Fixture {
    var documents: [String: [(origin: TemplateOrigin, fileName: String, content: String)]] = [:]
    var staged: [String: Data] = [:]
    var leased: [UUID: [String: Data]] = [:]
    var discarded: [String] = []
    var removeFailures = 0
    var removeAttempts = 0
    var retainFailures = 0
    var retainAttempts = 0
    var verifyAttempts = 0
    var corruptLeaseAfterVerify: Data?
    var commitFailureAfter: Int?

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
      staged = staged.filter { !$0.key.hasPrefix("\(path)|\(nodeID)|") }
    }

    func setRemoveFailures(_ count: Int) {
      removeFailures = count
    }

    func remove(path: String, nodeID: UUID, name: String) throws {
      let key = "\(path)|\(nodeID)|\(name)"
      guard staged[key] != nil else { return }
      removeAttempts += 1
      if removeFailures > 0 {
        removeFailures -= 1
        throw RemoteAssetError.transportFailure
      }
      staged.removeValue(forKey: key)
    }

    func remove(
      path: String, nodeID: UUID, descriptor: RemoteAssetRetentionDescriptor
    ) throws {
      let key = "\(path)|\(nodeID)|\(descriptor.name)"
      guard let data = staged[key] else { return }
      removeAttempts += 1
      if removeFailures > 0 {
        removeFailures -= 1
        throw RemoteAssetError.transportFailure
      }
      guard data.count == descriptor.size,
        RemoteAssetDigest.sha256Hex(data) == descriptor.sha256
      else { throw RemoteAssetError.hashMismatch }
      staged.removeValue(forKey: key)
    }

    func removeAttemptCount() -> Int {
      removeAttempts
    }

    func setRetainFailures(_ count: Int) {
      retainFailures = count
    }

    func retainAttemptCount() -> Int {
      retainAttempts
    }

    func stagedData(path: String, nodeID: UUID, name: String) -> Data? {
      staged["\(path)|\(nodeID)|\(name)"]
    }

    func replaceStaged(path: String, nodeID: UUID, name: String, data: Data) {
      staged["\(path)|\(nodeID)|\(name)"] = data
    }

    func corruptNextLeaseAfterVerify(with data: Data) {
      corruptLeaseAfterVerify = data
    }

    func failCommit(after descriptors: Int) {
      commitFailureAfter = descriptors
    }

    func resolve(path: String, nodeID: UUID, name: String, size: Int, sha256: String) throws
      -> String
    {
      guard let data = staged["\(path)|\(nodeID)|\(name)"], data.count == size,
        RemoteAssetDigest.sha256Hex(data) == sha256
      else { throw RemoteAssetError.hashMismatch }
      return "/synthetic/\(nodeID)/\(name)"
    }

    func retain(path: String, nodeID: UUID, names: Set<String>) throws {
      retainAttempts += 1
      if retainFailures > 0 {
        retainFailures -= 1
        throw RemoteAssetError.transportFailure
      }
      for name in names {
        guard staged["\(path)|\(nodeID)|\(name)"] != nil else {
          throw RemoteAssetError.missing
        }
      }
    }

    func acquireLease(
      path: String, nodeID: UUID, leaseID: UUID,
      descriptors: [RemoteAssetRetentionDescriptor]
    ) throws {
      retainAttempts += 1
      if retainFailures > 0 {
        retainFailures -= 1
        throw RemoteAssetError.transportFailure
      }
      var files: [String: Data] = [:]
      for descriptor in descriptors {
        let key = "\(path)|\(nodeID)|\(descriptor.name)"
        guard let data = staged[key], data.count == descriptor.size,
          RemoteAssetDigest.sha256Hex(data) == descriptor.sha256
        else { throw RemoteAssetError.hashMismatch }
        files[descriptor.name] = data
      }
      for descriptor in descriptors {
        staged.removeValue(forKey: "\(path)|\(nodeID)|\(descriptor.name)")
      }
      leased[leaseID] = files
    }

    func verifyLease(
      path: String, nodeID: UUID, leaseID: UUID,
      descriptors: [RemoteAssetRetentionDescriptor]
    ) throws {
      for descriptor in descriptors {
        let data =
          leased[leaseID]?[descriptor.name]
          ?? staged["\(path)|\(nodeID)|\(descriptor.name)"]
        guard let data, data.count == descriptor.size,
          RemoteAssetDigest.sha256Hex(data) == descriptor.sha256
        else { throw RemoteAssetError.hashMismatch }
      }
      verifyAttempts += 1
      if let replacement = corruptLeaseAfterVerify,
        let descriptor = descriptors.first
      {
        leased[leaseID]?[descriptor.name] = replacement
        corruptLeaseAfterVerify = nil
      }
    }

    func commitLease(
      path: String, nodeID: UUID, leaseID: UUID,
      descriptors: [RemoteAssetRetentionDescriptor]
    ) throws {
      try verifyLease(
        path: path, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
      var files = leased[leaseID] ?? [:]
      for descriptor in descriptors {
        let retainedKey = "\(path)|\(nodeID)|\(descriptor.name)"
        if let retained = staged[retainedKey], retained.count == descriptor.size,
          RemoteAssetDigest.sha256Hex(retained) == descriptor.sha256
        {
          files.removeValue(forKey: descriptor.name)
          continue
        }
        if let data = files.removeValue(forKey: descriptor.name) {
          staged["\(path)|\(nodeID)|\(descriptor.name)"] = data
        }
        if let remaining = commitFailureAfter {
          if remaining == 0 {
            leased[leaseID] = files
            commitFailureAfter = nil
            throw RemoteAssetError.transportFailure
          }
          commitFailureAfter = remaining - 1
        }
      }
      if files.isEmpty {
        leased.removeValue(forKey: leaseID)
      } else {
        leased[leaseID] = files
      }
    }

    func rollbackLease(leaseID: UUID) {
      leased.removeValue(forKey: leaseID)
    }

    func resolveLease(
      path: String, nodeID: UUID, leaseID: UUID,
      descriptor: RemoteAssetRetentionDescriptor
    ) throws -> String {
      try verifyLease(
        path: path, nodeID: nodeID, leaseID: leaseID, descriptors: [descriptor])
      return "/synthetic/\(nodeID)/\(descriptor.name)"
    }
  }

  private func store(
    fixture: Fixture, now: @escaping @Sendable () -> Date = { Date() },
    finalizedDraftLifetime: TimeInterval = RemoteAssetStore.finalizedDraftLifetime,
    catalogURL: URL? = nil,
    attachmentsDirectory: @escaping @Sendable (String, UUID) -> URL = {
      NodeMemory.attachmentsDirectory(forProjectPath: $0, nodeID: $1)
    }
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
        removeAttachment: { path, _, nodeID, name in
          try await fixture.remove(path: path, nodeID: nodeID, name: name)
        },
        removeStagedAttachment: { path, _, nodeID, descriptor in
          try await fixture.remove(path: path, nodeID: nodeID, descriptor: descriptor)
        },
        removeRetainedAttachment: { path, _, nodeID, descriptor in
          try await fixture.remove(path: path, nodeID: nodeID, descriptor: descriptor)
        },
        resolveAttachment: { path, _, nodeID, name, size, sha256 in
          try await fixture.resolve(
            path: path, nodeID: nodeID, name: name, size: size, sha256: sha256)
        },
        retainAttachments: { path, _, nodeID, names in
          try await fixture.retain(path: path, nodeID: nodeID, names: names)
        },
        acquireAttachmentLease: { path, _, nodeID, leaseID, descriptors in
          try await fixture.acquireLease(
            path: path, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
        },
        verifyAttachmentLease: { path, _, nodeID, leaseID, descriptors in
          try await fixture.verifyLease(
            path: path, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
        },
        commitAttachmentLease: { path, _, nodeID, leaseID, descriptors in
          try await fixture.commitLease(
            path: path, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
        },
        rollbackAttachmentLease: { _, _, _, leaseID, _ in
          await fixture.rollbackLease(leaseID: leaseID)
        },
        resolveLeasedAttachment: { path, _, nodeID, leaseID, descriptor in
          try await fixture.resolveLease(
            path: path, nodeID: nodeID, leaseID: leaseID, descriptor: descriptor)
        }),
      authenticationKey: Data(repeating: 0x41, count: 32),
      now: now,
      finalizedDraftLifetime: finalizedDraftLifetime,
      catalogURL: catalogURL,
      attachmentsDirectory: attachmentsDirectory)
  }

  private func finalize(
    _ store: RemoteAssetStore, owner: UUID, transferID: UUID
  ) async throws -> PromptAttachment {
    let attachment = try await store.finalize(owner: owner, transferID: transferID).get()
    _ = try await store.completeDelivery(
      owner: owner, deliveryID: transferID, delivered: true
    ).get()
    return attachment
  }

  private func declaration(name: String = "image-1.png", data: Data) -> AttachmentUploadDeclaration
  {
    AttachmentUploadDeclaration(
      name: name, contentType: "image/png", size: data.count,
      sha256: GraphcodeSHA256.digest(data).map { String(format: "%02x", $0) }.joined())
  }

  private func uploadThroughRegistry(
    _ registry: ProjectRegistry,
    connectionID: UUID,
    projectPath: String,
    nodeID: UUID,
    name: String = "image-1.png",
    data: Data
  ) async throws -> PromptAttachment {
    let began = await registry.apply(
      .beginAttachmentUpload(
        projectPath: projectPath, nodeID: nodeID,
        declaration: declaration(name: name, data: data)),
      connectionID: connectionID)
    guard case .attachmentUploadBegan(let ticket) = began?.response else {
      throw XCTSkip("attachment upload did not begin: \(began?.error ?? "no response")")
    }
    let appended = await registry.apply(
      .uploadAttachmentChunk(transferID: ticket.transferID, offset: 0, data: data),
      connectionID: connectionID)
    XCTAssertNil(appended?.error)
    let finalized = await registry.apply(
      .finalizeAttachmentUpload(transferID: ticket.transferID),
      connectionID: connectionID)
    guard case .attachmentStaged(let attachment) = finalized?.response else {
      throw XCTSkip("attachment upload did not finalize: \(finalized?.error ?? "no response")")
    }
    await registry.completeRemoteAssetDelivery(
      ticket.transferID, connectionID: connectionID, delivered: true)
    return attachment
  }

  private func uploadDraft(
    _ store: RemoteAssetStore,
    owner: UUID,
    projectPath: String,
    metadata: ProjectMetadata,
    nodeID: UUID,
    name: String = "image-1.png",
    data: Data
  ) async throws -> PromptAttachment {
    let ticket = try await store.beginUpload(
      owner: owner, projectPath: projectPath, metadata: metadata, nodeID: nodeID,
      declaration: declaration(name: name, data: data), existingCount: 0
    ).get()
    var offset = 0
    while offset < data.count {
      let end = min(offset + RemoteAssetStore.maximumChunkBytes, data.count)
      _ = try await store.append(
        owner: owner, transferID: ticket.transferID, offset: offset,
        data: data.subdata(in: offset..<end)
      ).get()
      offset = end
    }
    return try await finalize(store, owner: owner, transferID: ticket.transferID)
  }

  private func gatedStore(fixture: Fixture, gate: RemoteStageGate) -> RemoteAssetStore {
    RemoteAssetStore(
      transport: RemoteAssetHostTransport(
        templateDocuments: { path, _, _ in await fixture.readDocuments(path) },
        stageAttachment: { path, _, nodeID, name, data in
          await gate.suspend()
          return await fixture.stage(path: path, nodeID: nodeID, name: name, data: data)
        },
        discardAttachments: { path, _, nodeID in
          await fixture.discard(path: path, nodeID: nodeID)
        },
        removeAttachment: { path, _, nodeID, name in
          try await fixture.remove(path: path, nodeID: nodeID, name: name)
        },
        removeStagedAttachment: { path, _, nodeID, descriptor in
          try await fixture.remove(path: path, nodeID: nodeID, descriptor: descriptor)
        },
        removeRetainedAttachment: { path, _, nodeID, descriptor in
          try await fixture.remove(path: path, nodeID: nodeID, descriptor: descriptor)
        },
        resolveAttachment: { path, _, nodeID, name, size, sha256 in
          try await fixture.resolve(
            path: path, nodeID: nodeID, name: name, size: size, sha256: sha256)
        },
        retainAttachments: { path, _, nodeID, names in
          try await fixture.retain(path: path, nodeID: nodeID, names: names)
        },
        acquireAttachmentLease: { path, _, nodeID, leaseID, descriptors in
          try await fixture.acquireLease(
            path: path, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
        },
        verifyAttachmentLease: { path, _, nodeID, leaseID, descriptors in
          try await fixture.verifyLease(
            path: path, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
        },
        commitAttachmentLease: { path, _, nodeID, leaseID, descriptors in
          try await fixture.commitLease(
            path: path, nodeID: nodeID, leaseID: leaseID, descriptors: descriptors)
        },
        rollbackAttachmentLease: { _, _, _, leaseID, _ in
          await fixture.rollbackLease(leaseID: leaseID)
        },
        resolveLeasedAttachment: { path, _, nodeID, leaseID, descriptor in
          try await fixture.resolveLease(
            path: path, nodeID: nodeID, leaseID: leaseID, descriptor: descriptor)
        }),
      authenticationKey: Data(repeating: 0x42, count: 32))
  }

  private func waitForLaunches(
    _ count: Int, recorder: RemoteAssetLaunchRecorder
  ) async -> [LoopNode] {
    for _ in 0..<200 {
      let values = await recorder.values()
      if values.count >= count { return values }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await recorder.values()
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
      let attachment = try await finalize(store, owner: owner, transferID: ticket.transferID)
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
    let crossFinalize = await store.finalize(owner: UUID(), transferID: ticket.transferID)
    XCTAssertThrowsError(try crossFinalize.get())
    let crossCancel = await store.cancel(owner: UUID(), transferID: ticket.transferID)
    XCTAssertThrowsError(try crossCancel.get())
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
    let attachment = try await finalize(store, owner: owner, transferID: ticket.transferID)

    _ = try await store.validateForCreate(
      [attachment], owner: owner, projectPath: "ssh://fixture/repo", metadata: .ssh,
      nodeID: nodeID, allowsLegacyLocalPaths: false
    ).get()
    let crossProject = await store.validateForCreate(
      [attachment], owner: owner, projectPath: "codespace://fixture/repo", metadata: .ssh,
      nodeID: nodeID, allowsLegacyLocalPaths: false)
    XCTAssertThrowsError(try crossProject.get())
    let crossClassification = await store.validateForCreate(
      [attachment], owner: owner, projectPath: "ssh://fixture/repo", metadata: .codespace,
      nodeID: nodeID, allowsLegacyLocalPaths: false)
    XCTAssertThrowsError(try crossClassification.get())
    let crossNode = await store.validateForCreate(
      [attachment], owner: owner, projectPath: "ssh://fixture/repo", metadata: .ssh,
      nodeID: UUID(), allowsLegacyLocalPaths: false)
    XCTAssertThrowsError(try crossNode.get())
    let tampered = PromptAttachment(path: attachment.path + "x", name: attachment.name)
    let tamperedResult = await store.validateForCreate(
      [tampered], owner: owner, projectPath: "ssh://fixture/repo", metadata: .ssh,
      nodeID: nodeID, allowsLegacyLocalPaths: false)
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
      query: RemoteTemplateReadQuery(
        templateID: template.id, assetID: list.templates.first?.assetID, maxBytes: 4096)
    ).get()
    XCTAssertEqual(content.template.body, "Inspect the change")
    let tokenless = await store.readTemplate(
      owner: UUID(), projectPath: projectPath, metadata: .ssh,
      query: RemoteTemplateReadQuery(templateID: template.id, maxBytes: 4096))
    XCTAssertEqual(tokenless, .failure(.invalidReference))
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
      .announce(capabilities: [], clientID: UUID()),
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

  func testLogicalClientAnnouncementRemainsDecodableByLegacyDaemon() throws {
    let encoded = try JSONEncoder().encode(
      DaemonCommand.announce(capabilities: ["nodesChanged"], clientID: UUID()))
    XCTAssertEqual(
      try JSONDecoder().decode(LegacyAnnouncement.self, from: encoded),
      .announce(capabilities: ["nodesChanged"]))
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
    let attachment = try await finalize(store, owner: owner, transferID: ticket.transferID)
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

  private enum LegacyAnnouncement: Codable, Equatable {
    case announce(capabilities: [String])
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
    let attachment = try await finalize(store, owner: owner, transferID: ticket.transferID)
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
    let attachment = try await finalize(store, owner: owner, transferID: ticket.transferID)
    await fixture.replaceStaged(
      path: projectPath, nodeID: nodeID, name: attachment.fileName,
      data: Data("tampered".utf8))

    let result = await store.resolvedPath(
      for: attachment, projectPath: projectPath, nodeID: nodeID, metadata: .ssh)
    XCTAssertEqual(result, .failure(.hashMismatch))
  }

  func testFinalizingDraftRemovesOnlyUnselectedDraftFiles() async throws {
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
        try await finalize(store, owner: owner, transferID: ticket.transferID))
    }

    _ = try await store.commitCreate(
      [attachments[1]], owner: owner, projectPath: projectPath, metadata: .local, nodeID: nodeID
    ).get()

    let removed = await fixture.stagedData(
      path: projectPath, nodeID: nodeID, name: "image-1.png")
    let retained = await fixture.stagedData(
      path: projectPath, nodeID: nodeID, name: "image-2.png")
    XCTAssertNil(removed)
    XCTAssertNotNil(retained)

    _ = try await store.commitCreate(
      [], owner: owner, projectPath: projectPath, metadata: .local, nodeID: nodeID
    ).get()
    let committedFile = await fixture.stagedData(
      path: projectPath, nodeID: nodeID, name: "image-2.png")
    XCTAssertNotNil(committedFile)
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

  func testAggregateTransferLimitsBoundThousandsOfDraftNodesAndReleaseAccounting() async throws {
    let fixture = Fixture()
    let assetStore = store(fixture: fixture)
    let owner = UUID()
    let byte = Data([0x01])
    var tickets: [UUID] = []
    var exhausted = 0
    for index in 0..<1_000 {
      let result = await assetStore.beginUpload(
        owner: owner, projectPath: "C:\\aggregate", metadata: .local, nodeID: UUID(),
        declaration: declaration(name: "f-\(index).bin", data: byte), existingCount: 0)
      switch result {
      case .success(let ticket): tickets.append(ticket.transferID)
      case .failure(.resourceExhausted): exhausted += 1
      case .failure(let failure): XCTFail("unexpected failure \(failure)")
      }
    }
    XCTAssertEqual(tickets.count, RemoteAssetStore.maximumActiveTransfersPerOwner)
    XCTAssertEqual(exhausted, 1_000 - tickets.count)
    for ticket in tickets {
      _ = try await assetStore.cancel(owner: owner, transferID: ticket).get()
    }
    let releasedUsage = await assetStore.resourceUsage()
    XCTAssertEqual(
      releasedUsage,
      RemoteAssetUsageSnapshot(
        activeTransfers: 0, declaredBytes: 0, bufferedBytes: 0, pendingDeliveries: 0))

    let projectStore = self.store(fixture: Fixture())
    var projectTickets: [(UUID, UUID)] = []
    for index in 0..<RemoteAssetStore.maximumActiveTransfersPerProject {
      let transferOwner = UUID()
      let ticket = try await projectStore.beginUpload(
        owner: transferOwner, projectPath: "C:\\one-project", metadata: .local, nodeID: UUID(),
        declaration: declaration(name: "p-\(index).bin", data: byte), existingCount: 0
      ).get()
      projectTickets.append((transferOwner, ticket.transferID))
    }
    let projectOverflow = await projectStore.beginUpload(
      owner: UUID(), projectPath: "C:\\one-project", metadata: .local, nodeID: UUID(),
      declaration: declaration(name: "overflow.bin", data: byte), existingCount: 0)
    XCTAssertEqual(projectOverflow, .failure(.resourceExhausted))
    for (transferOwner, ticket) in projectTickets {
      _ = try await projectStore.cancel(owner: transferOwner, transferID: ticket).get()
    }

    let globalStore = self.store(fixture: Fixture())
    var globalTickets: [(UUID, UUID)] = []
    for index in 0..<RemoteAssetStore.maximumActiveTransfersGlobal {
      let transferOwner = UUID()
      let ticket = try await globalStore.beginUpload(
        owner: transferOwner, projectPath: "C:\\project-\(index)", metadata: .local,
        nodeID: UUID(), declaration: declaration(name: "g.bin", data: byte), existingCount: 0
      ).get()
      globalTickets.append((transferOwner, ticket.transferID))
    }
    let globalOverflow = await globalStore.beginUpload(
      owner: UUID(), projectPath: "C:\\overflow", metadata: .local, nodeID: UUID(),
      declaration: declaration(name: "g.bin", data: byte), existingCount: 0)
    XCTAssertEqual(globalOverflow, .failure(.resourceExhausted))
    for (transferOwner, ticket) in globalTickets {
      _ = try await globalStore.cancel(owner: transferOwner, transferID: ticket).get()
    }
  }

  func testDeclaredAndBufferedByteLimitsDoNotLeakOnDisconnect() async throws {
    let fixture = Fixture()
    let store = store(fixture: fixture)
    let owner = UUID()
    let maximum = AttachmentUploadDeclaration.maximumFileBytes
    var tickets: [UUID] = []
    for index in 0..<6 {
      let ticket = try await store.beginUpload(
        owner: owner, projectPath: "C:\\bytes", metadata: .local, nodeID: UUID(),
        declaration: AttachmentUploadDeclaration(
          name: "declared-\(index).bin", contentType: "application/octet-stream",
          size: maximum, sha256: String(repeating: "0", count: 64)),
        existingCount: 0
      ).get()
      tickets.append(ticket.transferID)
    }
    let declaredOverflow = await store.beginUpload(
      owner: owner, projectPath: "C:\\bytes", metadata: .local, nodeID: UUID(),
      declaration: AttachmentUploadDeclaration(
        name: "declared-overflow.bin", contentType: "application/octet-stream",
        size: maximum, sha256: String(repeating: "0", count: 64)),
      existingCount: 0)
    XCTAssertEqual(declaredOverflow, .failure(.resourceExhausted))
    await store.disconnected(owner: owner)
    let declaredReleased = await store.resourceUsage()
    XCTAssertEqual(declaredReleased.activeTransfers, 0)

    let bufferedOwner = UUID()
    var bufferedTickets: [UUID] = []
    for index in 0..<4 {
      let ticket = try await store.beginUpload(
        owner: bufferedOwner, projectPath: "C:\\buffered", metadata: .local, nodeID: UUID(),
        declaration: AttachmentUploadDeclaration(
          name: "buffered-\(index).bin", contentType: "application/octet-stream",
          size: maximum, sha256: String(repeating: "0", count: 64)),
        existingCount: 0
      ).get()
      bufferedTickets.append(ticket.transferID)
    }
    let chunk = Data(repeating: 0x55, count: RemoteAssetStore.maximumChunkBytes)
    var written = 0
    outer: for ticket in bufferedTickets {
      var offset = 0
      while offset < maximum {
        let result = await store.append(
          owner: bufferedOwner, transferID: ticket, offset: offset, data: chunk)
        if case .failure(.resourceExhausted) = result { break outer }
        offset = try result.get().nextOffset
        written += chunk.count
      }
    }
    XCTAssertEqual(written, RemoteAssetStore.maximumBufferedBytesPerOwner)
    let usage = await store.resourceUsage()
    XCTAssertEqual(usage.bufferedBytes, RemoteAssetStore.maximumBufferedBytesPerOwner)
    await store.disconnected(owner: bufferedOwner)
    let bufferedReleased = await store.resourceUsage()
    XCTAssertEqual(
      bufferedReleased,
      RemoteAssetUsageSnapshot(
        activeTransfers: 0, declaredBytes: 0, bufferedBytes: 0, pendingDeliveries: 0))
  }

  func testCancelAndDisconnectWaitForSuspendedFinalizeThenRemovePublication() async throws {
    for disconnect in [false, true] {
      let fixture = Fixture()
      let gate = RemoteStageGate()
      let store = gatedStore(fixture: fixture, gate: gate)
      let owner = UUID()
      let nodeID = UUID()
      let data = Data("race".utf8)
      let ticket = try await store.beginUpload(
        owner: owner, projectPath: "ssh://fixture/race", metadata: .ssh, nodeID: nodeID,
        declaration: declaration(data: data), existingCount: 0
      ).get()
      _ = try await store.append(
        owner: owner, transferID: ticket.transferID, offset: 0, data: data
      ).get()
      let finalizeTask = Task {
        await store.finalize(owner: owner, transferID: ticket.transferID)
      }
      while !(await gate.hasStarted()) { await Task.yield() }
      let cancellation = Task {
        if disconnect {
          await store.disconnected(owner: owner)
          return Result<Void, RemoteAssetError>.success(())
        }
        return await store.cancel(owner: owner, transferID: ticket.transferID)
      }
      try await Task.sleep(for: .milliseconds(20))
      await gate.release()
      _ = try await cancellation.value.get()
      let finalizeResult = await finalizeTask.value
      XCTAssertThrowsError(try finalizeResult.get())
      let staged = await fixture.stagedData(
        path: "ssh://fixture/race", nodeID: nodeID, name: "image-1.png")
      XCTAssertNil(staged)
      let usage = await store.resourceUsage()
      XCTAssertEqual(usage.activeTransfers, 0)
    }
  }

  func testReferenceDeliveryFailureRetriesCleanupAndReleasesPublishedFile() async throws {
    let fixture = Fixture()
    await fixture.setRemoveFailures(3)
    let store = store(fixture: fixture)
    let owner = UUID()
    let nodeID = UUID()
    let path = "codespace://fixture/delivery"
    let data = Data("delivery".utf8)
    let ticket = try await store.beginUpload(
      owner: owner, projectPath: path, metadata: .codespace, nodeID: nodeID,
      declaration: declaration(data: data), existingCount: 0
    ).get()
    _ = try await store.append(
      owner: owner, transferID: ticket.transferID, offset: 0, data: data
    ).get()
    _ = try await store.finalize(owner: owner, transferID: ticket.transferID).get()
    let firstCleanup = await store.completeDelivery(
      owner: owner, deliveryID: ticket.transferID, delivered: false
    )
    XCTAssertThrowsError(try firstCleanup.get())
    let cleaned = await store.resourceUsage()
    let attempts = await fixture.removeAttemptCount()
    let staged = await fixture.stagedData(path: path, nodeID: nodeID, name: "image-1.png")
    let usage = await store.resourceUsage()
    XCTAssertEqual(attempts, 4)
    XCTAssertNil(staged)
    XCTAssertEqual(cleaned.pendingDeliveries, 0)
    XCTAssertEqual(usage.pendingDraftCleanups, 0)
  }

  func testTemplateIdentityRejectsCollisionsOrderChangesAndOriginSubstitution() async throws {
    let fixture = Fixture()
    let store = store(fixture: fixture)
    let projectPath = "ssh://fixture/templates"
    let sharedID = UUID()
    let home = PromptTemplate(id: sharedID, name: "Home", body: "trusted")
    let project = PromptTemplate(id: sharedID, name: "Project", body: "untrusted")
    let collisionOrders: [[(TemplateOrigin, String, String)]] = [
      [
        (.home, "home.md", TemplateFileCodec.encode(home)),
        (.project(projectPath), "project.md", TemplateFileCodec.encode(project)),
      ],
      [
        (.project(projectPath), "project.md", TemplateFileCodec.encode(project)),
        (.home, "home.md", TemplateFileCodec.encode(home)),
      ],
    ]
    for documents in collisionOrders {
      await fixture.setDocuments(documents, for: projectPath)
      let result = await store.listTemplates(
        owner: UUID(), projectPath: projectPath, metadata: .ssh,
        query: RemoteTemplateListQuery(maxCount: 8, maxBytes: 16 * 1024))
      XCTAssertEqual(result, .failure(.ambiguousTemplate))
    }

    await fixture.setDocuments(
      [(.home, "home.md", TemplateFileCodec.encode(home))], for: projectPath)
    let list = try await store.listTemplates(
      owner: UUID(), projectPath: projectPath, metadata: .ssh,
      query: RemoteTemplateListQuery(maxCount: 8, maxBytes: 16 * 1024)
    ).get()
    let listed = try XCTUnwrap(list.templates.first)
    await fixture.setDocuments(
      [(.project(projectPath), "home.md", TemplateFileCodec.encode(project))], for: projectPath)
    let substituted = await store.readTemplate(
      owner: UUID(), projectPath: projectPath, metadata: .ssh,
      query: RemoteTemplateReadQuery(
        templateID: listed.id, assetID: listed.assetID, maxBytes: 16 * 1024))
    XCTAssertEqual(substituted, .failure(.invalidReference))

    let mutated = PromptTemplate(id: sharedID, name: "Home", body: "changed")
    await fixture.setDocuments(
      [(.home, "home.md", TemplateFileCodec.encode(mutated))], for: projectPath)
    let changed = await store.readTemplate(
      owner: UUID(), projectPath: projectPath, metadata: .ssh,
      query: RemoteTemplateReadQuery(
        templateID: listed.id, assetID: listed.assetID, maxBytes: 16 * 1024))
    XCTAssertEqual(changed, .failure(.invalidReference))
  }

  func testLegacyLocalPathsAreNarrowlyContainedAndV2RequiresOpaqueReferences() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("legacy-assets-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = root.appendingPathComponent("attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let fixture = Fixture()
    let store = store(
      fixture: fixture,
      attachmentsDirectory: { _, _ in staging })
    let owner = UUID()
    let nodeID = UUID()
    let safe = staging.appendingPathComponent("safe.png")
    try Data("safe".utf8).write(to: safe)
    let safeAttachment = PromptAttachment(path: safe.path, name: "safe.png")
    _ = try await store.validateForCreate(
      [safeAttachment], owner: owner, projectPath: "C:\\legacy", metadata: .local,
      nodeID: nodeID, allowsLegacyLocalPaths: true
    ).get()
    let resolved = try await store.resolvedPath(
      for: safeAttachment, projectPath: "C:\\legacy", nodeID: nodeID, metadata: .local
    ).get()
    XCTAssertEqual(resolved, safe.standardizedFileURL.path)
    let modernValidation = await store.validateForCreate(
      [safeAttachment], owner: owner, projectPath: "C:\\legacy", metadata: .local,
      nodeID: nodeID, allowsLegacyLocalPaths: false)
    XCTAssertThrowsError(try modernValidation.get())

    let privateFile = root.appendingPathComponent("private.png")
    try Data("private".utf8).write(to: privateFile)
    for denied in [
      PromptAttachment(path: privateFile.path, name: "private.png"),
      PromptAttachment(
        path: staging.appendingPathComponent("..\\private.png").path, name: "private.png"),
    ] {
      let deniedResult = await store.validateForCreate(
        [denied], owner: owner, projectPath: "C:\\legacy", metadata: .local,
        nodeID: nodeID, allowsLegacyLocalPaths: true)
      XCTAssertThrowsError(try deniedResult.get())
    }

    let hardlink = staging.appendingPathComponent("hardlink.png")
    try FileManager.default.linkItem(at: privateFile, to: hardlink)
    let hardlinkResult = await store.validateForCreate(
      [PromptAttachment(path: hardlink.path, name: "hardlink.png")], owner: owner,
      projectPath: "C:\\legacy", metadata: .local, nodeID: nodeID,
      allowsLegacyLocalPaths: true)
    XCTAssertThrowsError(try hardlinkResult.get())
    let symlink = staging.appendingPathComponent("symlink.png")
    if (try? FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: privateFile))
      != nil
    {
      let symlinkResult = await store.validateForCreate(
        [PromptAttachment(path: symlink.path, name: "symlink.png")], owner: owner,
        projectPath: "C:\\legacy", metadata: .local, nodeID: nodeID,
        allowsLegacyLocalPaths: true)
      XCTAssertThrowsError(try symlinkResult.get())
    }

    let registry = ProjectRegistry(
      persistenceDirectory: root.appendingPathComponent("state"),
      remoteAssets: store,
      ensureSession: nil,
      terminateSession: nil,
      restartSession: nil,
      persistsSynchronously: true,
      classifyProject: { _ in .local })
    let legacy = RemoteAssetTestConnection()
    let modern = RemoteAssetTestConnection()
    await registry.addConnection(
      id: legacy.id,
      channel: DaemonConnectionChannel(connection: legacy, mode: .v1))
    await registry.addConnection(
      id: modern.id,
      channel: DaemonConnectionChannel(connection: modern, mode: .v2(version: 2)))
    _ = await registry.apply(.openProject(path: root.path), connectionID: legacy.id)
    _ = await registry.apply(.openProject(path: root.path), connectionID: modern.id)
    let legacyID = UUID()
    _ = await fixture.stage(
      path: root.path, nodeID: legacyID, name: "safe.png", data: Data("safe".utf8))
    let accepted = await registry.apply(
      .graphCommand(
        projectPath: root.path,
        command: .createNode(
          NodeDraft(
            id: legacyID, title: "Legacy", loopType: .turnBased,
            firstInstruction: "work", attachments: [safeAttachment]))),
      connectionID: legacy.id)
    XCTAssertNil(accepted?.error)
    let modernRejected = await registry.apply(
      .graphCommand(
        projectPath: root.path,
        command: .createNode(
          NodeDraft(
            title: "Modern path", loopType: .turnBased, firstInstruction: "work",
            attachments: [safeAttachment]))),
      connectionID: modern.id)
    XCTAssertEqual(modernRejected?.errorCode, .remoteAssetInvalidReference)
    let privateRejected = await registry.apply(
      .graphCommand(
        projectPath: root.path,
        command: .createNode(
          NodeDraft(
            title: "Private path", loopType: .turnBased, firstInstruction: "work",
            attachments: [PromptAttachment(path: privateFile.path, name: "private.png")]))),
      connectionID: legacy.id)
    XCTAssertEqual(privateRejected?.errorCode, .remoteAssetInvalidReference)
    let snapshot = try JSONEncoder().encode(accepted?.response)
    XCTAssertFalse(String(decoding: snapshot, as: UTF8.self).contains(privateFile.path))
  }

  func testCommonLaunchBoundaryResolvesAttendedUnattendedRestartRecoveryAndLiveness()
    async throws
  {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("launch-assets-\(UUID())", isDirectory: true)
    let localProject = root.appendingPathComponent("local", isDirectory: true)
    try FileManager.default.createDirectory(at: localProject, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture()
    let assets = store(fixture: fixture)
    let attendedStarts = RemoteAssetLaunchRecorder()
    let localRegistry = ProjectRegistry(
      persistenceDirectory: root.appendingPathComponent("local-state"),
      remoteAssets: assets,
      ensureSession: nil,
      terminateSession: nil,
      restartSession: nil,
      startNodeSession: { node, _ in
        await attendedStarts.record(node)
        return .success(.started)
      },
      nodeSessionExists: { _, _ in false },
      findMissingProvider: { _, _ in nil },
      persistsSynchronously: true,
      classifyProject: { _ in .local })
    let localConnection = RemoteAssetTestConnection()
    await localRegistry.addConnection(
      id: localConnection.id,
      channel: DaemonConnectionChannel(
        connection: localConnection, mode: .v2(version: 2)))
    _ = await localRegistry.apply(
      .openProject(path: localProject.path), connectionID: localConnection.id)
    let attendedID = UUID()
    let attendedData = Data("attended".utf8)
    let attendedTicket = try await assets.beginUpload(
      owner: localConnection.id, projectPath: localProject.path, metadata: .local,
      nodeID: attendedID, declaration: declaration(data: attendedData), existingCount: 0
    ).get()
    _ = try await assets.append(
      owner: localConnection.id, transferID: attendedTicket.transferID, offset: 0,
      data: attendedData
    ).get()
    let attendedAttachment = try await assets.finalize(
      owner: localConnection.id, transferID: attendedTicket.transferID
    ).get()
    _ = try await assets.completeDelivery(
      owner: localConnection.id, deliveryID: attendedTicket.transferID, delivered: true
    ).get()
    let createdAttended = await localRegistry.apply(
      .graphCommand(
        projectPath: localProject.path,
        command: .createNode(
          NodeDraft(
            id: attendedID, title: "Attended", loopType: .turnBased,
            firstInstruction: "work",
            attachments: [attendedAttachment]))),
      connectionID: localConnection.id)
    XCTAssertNil(createdAttended?.error)
    let opened = await localRegistry.apply(
      .openNodeSession(projectPath: localProject.path, nodeID: attendedID),
      connectionID: localConnection.id)
    XCTAssertNil(opened?.error)
    let attendedLaunches = await attendedStarts.values()
    XCTAssertEqual(
      attendedLaunches.first?.attachments.first?.path,
      "/synthetic/\(attendedID)/image-1.png")

    let remotePath = "ssh://fixture/launch"
    let ensureStarts = RemoteAssetLaunchRecorder()
    let restarts = RemoteAssetLaunchRecorder()
    let remoteState = root.appendingPathComponent("remote-state")
    let remoteRegistry = ProjectRegistry(
      persistenceDirectory: remoteState,
      remoteAssets: assets,
      ensureSession: { node, _ in await ensureStarts.record(node) },
      terminateSession: nil,
      restartSession: { node, _ in
        await restarts.record(node)
        return true
      },
      persistsSynchronously: true,
      classifyProject: { _ in .ssh })
    let remoteConnection = RemoteAssetTestConnection()
    await remoteRegistry.addConnection(
      id: remoteConnection.id,
      channel: DaemonConnectionChannel(
        connection: remoteConnection, mode: .v2(version: 2)))
    _ = await remoteRegistry.apply(
      .openProject(path: remotePath), connectionID: remoteConnection.id)
    let unattendedID = UUID()
    let unattendedData = Data("unattended".utf8)
    let unattendedTicket = try await assets.beginUpload(
      owner: remoteConnection.id, projectPath: remotePath, metadata: .ssh,
      nodeID: unattendedID, declaration: declaration(data: unattendedData), existingCount: 0
    ).get()
    _ = try await assets.append(
      owner: remoteConnection.id, transferID: unattendedTicket.transferID, offset: 0,
      data: unattendedData
    ).get()
    let unattendedAttachment = try await assets.finalize(
      owner: remoteConnection.id, transferID: unattendedTicket.transferID
    ).get()
    _ = try await assets.completeDelivery(
      owner: remoteConnection.id, deliveryID: unattendedTicket.transferID, delivered: true
    ).get()
    let createdUnattended = await remoteRegistry.apply(
      .graphCommand(
        projectPath: remotePath,
        command: .createNode(
          NodeDraft(
            id: unattendedID, title: "Unattended", loopType: .timeBased,
            triggerPrompt: "/loop 1h Work", attachments: [unattendedAttachment]))),
      connectionID: remoteConnection.id)
    XCTAssertNil(createdUnattended?.error)
    var launches = await waitForLaunches(1, recorder: ensureStarts)
    XCTAssertEqual(
      launches.first?.attachments.first?.path, "/synthetic/\(unattendedID)/image-1.png")

    let restarted = await remoteRegistry.apply(
      .graphCommand(projectPath: remotePath, command: .restartNode(unattendedID)),
      connectionID: remoteConnection.id)
    XCTAssertNil(restarted?.error)
    let restartLaunches = await waitForLaunches(1, recorder: restarts)
    XCTAssertEqual(
      restartLaunches.first?.attachments.first?.path,
      "/synthetic/\(unattendedID)/image-1.png")

    await ensureStarts.clear()
    await remoteRegistry.ensureRemoteSessionsAlive()
    launches = await waitForLaunches(1, recorder: ensureStarts)
    XCTAssertEqual(
      launches.first?.attachments.first?.path, "/synthetic/\(unattendedID)/image-1.png")

    let recoveryStarts = RemoteAssetLaunchRecorder()
    let recoveryRegistry = ProjectRegistry(
      persistenceDirectory: remoteState,
      remoteAssets: assets,
      ensureSession: { node, _ in await recoveryStarts.record(node) },
      terminateSession: nil,
      restartSession: nil,
      persistsSynchronously: true,
      classifyProject: { _ in .ssh })
    let recoveryConnection = RemoteAssetTestConnection()
    await recoveryRegistry.addConnection(
      id: recoveryConnection.id,
      channel: DaemonConnectionChannel(
        connection: recoveryConnection, mode: .v2(version: 2)))
    _ = await recoveryRegistry.apply(
      .openProject(path: remotePath), connectionID: recoveryConnection.id)
    let recoveredLaunches = await waitForLaunches(1, recorder: recoveryStarts)
    XCTAssertEqual(
      recoveredLaunches.first?.attachments.first?.path,
      "/synthetic/\(unattendedID)/image-1.png")

    await fixture.replaceStaged(
      path: remotePath, nodeID: unattendedID, name: "image-1.png",
      data: Data("tampered".utf8))
    await ensureStarts.clear()
    await remoteRegistry.ensureRemoteSessionsAlive()
    try? await Task.sleep(for: .milliseconds(50))
    let tamperedLaunches = await ensureStarts.values()
    XCTAssertTrue(tamperedLaunches.isEmpty)
  }

  func testLaunchAndReferenceUseRequireJoinedCanonicalProjectAndOwningConnection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-authority-\(UUID())", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture()
    let assets = store(fixture: fixture)
    let starts = RemoteAssetLaunchRecorder()
    let registry = ProjectRegistry(
      persistenceDirectory: root.appendingPathComponent("state"),
      remoteAssets: assets,
      ensureSession: nil,
      terminateSession: nil,
      restartSession: nil,
      startNodeSession: { node, _ in
        await starts.record(node)
        return .success(.started)
      },
      nodeSessionExists: { _, _ in false },
      findMissingProvider: { _, _ in nil },
      persistsSynchronously: true,
      classifyProject: { _ in .local })
    let owner = RemoteAssetTestConnection()
    let peer = RemoteAssetTestConnection()
    for connection in [owner, peer] {
      await registry.addConnection(
        id: connection.id,
        channel: DaemonConnectionChannel(
          connection: connection, mode: .v2(version: 2)))
    }
    _ = await registry.apply(.openProject(path: project.path), connectionID: owner.id)
    let nodeID = UUID()
    let data = Data("owned".utf8)
    let ticket = try await assets.beginUpload(
      owner: owner.id, projectPath: project.path, metadata: .local, nodeID: nodeID,
      declaration: declaration(data: data), existingCount: 0
    ).get()
    _ = try await assets.append(
      owner: owner.id, transferID: ticket.transferID, offset: 0, data: data
    ).get()
    let attachment = try await assets.finalize(
      owner: owner.id, transferID: ticket.transferID
    ).get()
    _ = try await assets.completeDelivery(
      owner: owner.id, deliveryID: ticket.transferID, delivered: true
    ).get()
    _ = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(
            id: nodeID, title: "Owned", loopType: .turnBased, firstInstruction: "work",
            attachments: [attachment]))),
      connectionID: owner.id)

    let unjoined = await registry.apply(
      .openNodeSession(
        projectPath: project.appendingPathComponent("nested").path, nodeID: nodeID),
      connectionID: peer.id)
    XCTAssertEqual(unjoined?.errorCode, .remoteAssetUnauthorized)
    let unauthorizedStarts = await starts.values()
    XCTAssertTrue(unauthorizedStarts.isEmpty)
    _ = await registry.apply(.openProject(path: project.path), connectionID: peer.id)
    let wrongNode = await registry.apply(
      .openNodeSession(projectPath: project.path, nodeID: UUID()),
      connectionID: peer.id)
    XCTAssertNotNil(wrongNode?.error)
    let stolen = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(
            id: UUID(), title: "Stolen", loopType: .turnBased, firstInstruction: "work",
            attachments: [attachment]))),
      connectionID: peer.id)
    XCTAssertEqual(stolen?.errorCode, .remoteAssetInvalidReference)
  }

  func testDuplicateCreateAndUploadCannotDeleteExistingNodeAttachments() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-duplicate-\(UUID())", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture()
    let assets = store(fixture: fixture)
    let registry = ProjectRegistry(
      persistenceDirectory: root.appendingPathComponent("state"),
      remoteAssets: assets,
      ensureSession: nil,
      terminateSession: nil,
      restartSession: nil,
      persistsSynchronously: true,
      classifyProject: { _ in .local })
    let owner = RemoteAssetTestConnection()
    await registry.addConnection(
      id: owner.id,
      channel: DaemonConnectionChannel(connection: owner, mode: .v2(version: 2)))
    _ = await registry.apply(.openProject(path: project.path), connectionID: owner.id)
    let nodeID = UUID()
    let data = Data("existing".utf8)
    let ticket = try await assets.beginUpload(
      owner: owner.id, projectPath: project.path, metadata: .local, nodeID: nodeID,
      declaration: declaration(data: data), existingCount: 0
    ).get()
    _ = try await assets.append(
      owner: owner.id, transferID: ticket.transferID, offset: 0, data: data
    ).get()
    let attachment = try await assets.finalize(
      owner: owner.id, transferID: ticket.transferID
    ).get()
    _ = try await assets.completeDelivery(
      owner: owner.id, deliveryID: ticket.transferID, delivered: true
    ).get()
    let created = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(
            id: nodeID, title: "Existing", loopType: .turnBased,
            firstInstruction: "work",
            attachments: [attachment]))),
      connectionID: owner.id)
    XCTAssertNil(created?.error)

    let duplicate = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(
            id: nodeID, title: "Duplicate", loopType: .turnBased,
            firstInstruction: "work"))),
      connectionID: owner.id)
    XCTAssertNotNil(duplicate?.error)
    let existingAfterDuplicate = await fixture.stagedData(
      path: project.path, nodeID: nodeID, name: "image-1.png")
    XCTAssertEqual(
      existingAfterDuplicate,
      data)
    let upload = await registry.apply(
      .beginAttachmentUpload(
        projectPath: project.path, nodeID: nodeID,
        declaration: declaration(name: "new.png", data: Data("new".utf8))),
      connectionID: owner.id)
    XCTAssertEqual(upload?.errorCode, .remoteAssetUnauthorized)
    let existingAfterUpload = await fixture.stagedData(
      path: project.path, nodeID: nodeID, name: "image-1.png")
    XCTAssertEqual(
      existingAfterUpload,
      data)
  }

  func testLogicalClientOwnsDraftAcrossUploadAndGraphConnections() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-logical-owner-\(UUID())", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture()
    let assets = store(fixture: fixture)
    let registry = ProjectRegistry(
      persistenceDirectory: root.appendingPathComponent("state"),
      remoteAssets: assets,
      ensureSession: nil,
      terminateSession: nil,
      restartSession: nil,
      persistsSynchronously: true,
      classifyProject: { _ in .local })
    let peerProcessID: UInt64 = 4_242
    let logicalClientID = UUID()
    let upload = RemoteAssetTestConnection(peerProcessID: peerProcessID)
    let graph = RemoteAssetTestConnection(peerProcessID: peerProcessID)
    let other = RemoteAssetTestConnection(peerProcessID: peerProcessID)
    await registry.addConnection(
      id: upload.id,
      channel: DaemonConnectionChannel(
        connection: upload, mode: .v2(version: 2), clientID: logicalClientID))
    await registry.addConnection(
      id: graph.id, channel: DaemonConnectionChannel(connection: graph, mode: .v1))
    await registry.addConnection(
      id: other.id, channel: DaemonConnectionChannel(connection: other, mode: .v1))
    let graphIdentity = await registry.apply(
      .announce(capabilities: [], clientID: logicalClientID), connectionID: graph.id)
    XCTAssertNil(graphIdentity?.error)
    let otherIdentity = await registry.apply(
      .announce(capabilities: [], clientID: UUID()), connectionID: other.id)
    XCTAssertNil(otherIdentity?.error)
    for connectionID in [upload.id, graph.id, other.id] {
      _ = await registry.apply(.openProject(path: project.path), connectionID: connectionID)
    }

    let nodeID = UUID()
    let data = Data("logical owner".utf8)
    let attachment = try await uploadThroughRegistry(
      registry, connectionID: upload.id, projectPath: project.path, nodeID: nodeID, data: data)
    let refused = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(
            id: nodeID, title: "Wrong owner", loopType: .turnBased,
            firstInstruction: "work", attachments: [attachment]))),
      connectionID: other.id)
    XCTAssertEqual(refused?.errorCode, .remoteAssetUnauthorized)

    await registry.removeConnection(upload.id)
    let persisted = await fixture.stagedData(
      path: project.path, nodeID: nodeID, name: "image-1.png")
    XCTAssertEqual(persisted, data)
    let created = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(
            id: nodeID, title: "Shared owner", loopType: .turnBased,
            firstInstruction: "work", attachments: [attachment]))),
      connectionID: graph.id)
    XCTAssertNil(created?.error)

    let secondUpload = RemoteAssetTestConnection(peerProcessID: peerProcessID)
    await registry.addConnection(
      id: secondUpload.id,
      channel: DaemonConnectionChannel(
        connection: secondUpload, mode: .v2(version: 2), clientID: logicalClientID))
    _ = await registry.apply(.openProject(path: project.path), connectionID: secondUpload.id)
    let abandonedID = UUID()
    let abandonedData = Data("abandoned".utf8)
    _ = try await uploadThroughRegistry(
      registry, connectionID: secondUpload.id, projectPath: project.path, nodeID: abandonedID,
      data: abandonedData)
    await registry.removeConnection(secondUpload.id)
    let abandonedStaged = await fixture.stagedData(
      path: project.path, nodeID: abandonedID, name: "image-1.png")
    XCTAssertEqual(abandonedStaged, abandonedData)
    await registry.removeConnection(graph.id)
    let cleaned = await fixture.stagedData(
      path: project.path, nodeID: abandonedID, name: "image-1.png")
    XCTAssertNil(cleaned)
  }

  func testRetentionFailureNeverPublishesTopLevelOrDeeplyNestedCreate() async throws {
    for metadata in [ProjectMetadata.local, .ssh] {
      for nested in [false, true] {
        let root = FileManager.default.temporaryDirectory
          .appendingPathComponent("asset-retain-failure-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path =
          metadata.location == .local
          ? root.appendingPathComponent("project", isDirectory: true).path
          : "ssh://fixture/project-\(UUID())"
        if metadata.location == .local {
          try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
        }
        let project = ProjectRef(path: path, name: "Project", metadata: metadata)
        let outerID = UUID()
        let innerID = UUID()
        let initial: LoopGraph
        if nested {
          let leaf = LoopGraph(project: project)
          let middle = LoopGraph(
            project: project,
            nodes: [
              LoopNode(id: innerID, title: "Inner", loopType: .composite, subGraph: leaf)
            ])
          initial = LoopGraph(
            project: project,
            nodes: [
              LoopNode(id: outerID, title: "Outer", loopType: .composite, subGraph: middle)
            ])
        } else {
          initial = LoopGraph(project: project)
        }
        let state = root.appendingPathComponent("state", isDirectory: true)
        ProjectPersistence(baseDirectory: state).saveGraph(initial)
        let fixture = Fixture()
        let assets = store(fixture: fixture)
        let replay = DaemonReplayStore()
        let registry = ProjectRegistry(
          persistenceDirectory: state, replayStore: replay, remoteAssets: assets,
          ensureSession: nil, terminateSession: nil, restartSession: nil,
          persistsSynchronously: true, classifyProject: { _ in metadata })
        let clientID = UUID()
        let connection = RemoteAssetTestConnection(peerProcessID: 9_001)
        await registry.addConnection(
          id: connection.id,
          channel: DaemonConnectionChannel(
            connection: connection, mode: .v2(version: 2), clientID: clientID,
            replayStore: replay))
        _ = await registry.apply(.openProject(path: path), connectionID: connection.id)

        let nodeID = UUID()
        let existing = Data("existing".utf8)
        _ = await fixture.stage(
          path: path, nodeID: nodeID, name: "existing.png", data: existing)
        let attachment = try await uploadThroughRegistry(
          registry, connectionID: connection.id, projectPath: path, nodeID: nodeID,
          data: Data("draft".utf8))
        let framesBefore = connection.sentFrames().count
        let replayBefore = try? replay.replay(clientID: clientID, after: 0).count
        await fixture.setRetainFailures(1)

        let create = GraphCommand.createNode(
          NodeDraft(
            id: nodeID, title: "Must not exist", loopType: .turnBased,
            firstInstruction: "work", attachments: [attachment]))
        let command =
          nested
          ? GraphCommand.subGraphCommand(
            nodeID: outerID,
            command: .subGraphCommand(nodeID: innerID, command: create))
          : create
        let result = await registry.apply(
          .graphCommand(projectPath: path, command: command),
          connectionID: connection.id)

        XCTAssertEqual(result?.errorCode, .remoteAssetTransportFailure)
        XCTAssertNil(result?.response)
        XCTAssertEqual(connection.sentFrames().count, framesBefore)
        let replayAfter = try? replay.replay(clientID: clientID, after: 0).count
        XCTAssertEqual(replayAfter, replayBefore)
        XCTAssertFalse(
          ProjectPersistence(baseDirectory: state).loadGraph(path: path)?
            .nodesAtAnyDepth.contains(where: { $0.id == nodeID }) ?? true)
        let removedDraft = await fixture.stagedData(
          path: path, nodeID: nodeID, name: attachment.fileName)
        let existingAfterFailure = await fixture.stagedData(
          path: path, nodeID: nodeID, name: "existing.png")
        XCTAssertNil(removedDraft)
        XCTAssertEqual(existingAfterFailure, existing)

        await registry.removeConnection(connection.id)
        let existingAfterDisconnect = await fixture.stagedData(
          path: path, nodeID: nodeID, name: "existing.png")
        XCTAssertEqual(existingAfterDisconnect, existing)
        let restarted = ProjectRegistry(
          persistenceDirectory: state, remoteAssets: store(fixture: fixture),
          ensureSession: nil, terminateSession: nil, restartSession: nil,
          persistsSynchronously: true, classifyProject: { _ in metadata })
        let restartConnection = RemoteAssetTestConnection(peerProcessID: 9_002)
        await restarted.addConnection(
          id: restartConnection.id,
          channel: DaemonConnectionChannel(connection: restartConnection, mode: .v1))
        let reopened = await restarted.apply(
          .openProject(path: path), connectionID: restartConnection.id)
        guard case .graphChanged(let graph) = reopened?.response else {
          return XCTFail("expected persisted graph after restart")
        }
        XCTAssertFalse(graph.nodesAtAnyDepth.contains(where: { $0.id == nodeID }))
        await restarted.removeConnection(restartConnection.id)
      }
    }
  }

  func testFinalizedDraftLimitsExpiryAndCleanupRetryDoNotLeakAccounting() async throws {
    let fixture = Fixture()
    let owner = UUID()
    let path = "ssh://fixture/long-lived"
    let clock = RemoteAssetTestClock(Date(timeIntervalSince1970: 10_000))
    let assets = store(fixture: fixture, now: { clock.now() })

    for index in 0..<RemoteAssetStore.maximumFinalizedDraftsPerOwner {
      _ = try await uploadDraft(
        assets, owner: owner, projectPath: path, metadata: .ssh, nodeID: UUID(),
        name: "count-\(index).png", data: Data([UInt8(index % 255)]))
    }
    let countUsage = await assets.resourceUsage()
    XCTAssertEqual(countUsage.finalizedDrafts, RemoteAssetStore.maximumFinalizedDraftsPerOwner)
    XCTAssertEqual(
      countUsage.finalizedAttachments, RemoteAssetStore.maximumFinalizedDraftsPerOwner)
    let rejectedNode = UUID()
    let rejectedTicket = try await assets.beginUpload(
      owner: owner, projectPath: path, metadata: .ssh, nodeID: rejectedNode,
      declaration: declaration(name: "over-count.png", data: Data([1])), existingCount: 0
    ).get()
    _ = try await assets.append(
      owner: owner, transferID: rejectedTicket.transferID, offset: 0, data: Data([1])
    ).get()
    let countRejection = await assets.finalize(
      owner: owner, transferID: rejectedTicket.transferID)
    guard case .failure(.resourceExhausted) = countRejection else {
      return XCTFail("expected finalized draft count rejection")
    }

    await assets.disconnected(owner: owner)
    let countReleased = await assets.resourceUsage()
    XCTAssertEqual(
      countReleased,
      RemoteAssetUsageSnapshot(
        activeTransfers: 0, declaredBytes: 0, bufferedBytes: 0, pendingDeliveries: 0))

    let byteOwner = UUID()
    let chunk = Data(repeating: 0x5a, count: AttachmentUploadDeclaration.maximumFileBytes)
    for index in 0..<6 {
      _ = try await uploadDraft(
        assets, owner: byteOwner, projectPath: path, metadata: .ssh, nodeID: UUID(),
        name: "bytes-\(index).png", data: chunk)
    }
    let overflowNode = UUID()
    let overflowTicket = try await assets.beginUpload(
      owner: byteOwner, projectPath: path, metadata: .ssh, nodeID: overflowNode,
      declaration: declaration(name: "bytes-over.png", data: chunk), existingCount: 0
    ).get()
    var offset = 0
    while offset < chunk.count {
      let end = min(offset + RemoteAssetStore.maximumChunkBytes, chunk.count)
      _ = try await assets.append(
        owner: byteOwner, transferID: overflowTicket.transferID, offset: offset,
        data: chunk.subdata(in: offset..<end)
      ).get()
      offset = end
    }
    let byteRejection = await assets.finalize(
      owner: byteOwner, transferID: overflowTicket.transferID)
    guard case .failure(.resourceExhausted) = byteRejection else {
      return XCTFail("expected finalized draft byte rejection")
    }
    let byteUsage = await assets.resourceUsage()
    XCTAssertEqual(byteUsage.finalizedBytes, 60 * 1024 * 1024)
    await assets.disconnected(owner: byteOwner)

    let state = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-draft-expiry-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    let registry = ProjectRegistry(
      persistenceDirectory: state, remoteAssets: assets,
      ensureSession: nil, terminateSession: nil, restartSession: nil,
      persistsSynchronously: true, classifyProject: { _ in .ssh })
    let liveConnection = RemoteAssetTestConnection(peerProcessID: 7_001)
    let liveClientID = UUID()
    await registry.addConnection(
      id: liveConnection.id,
      channel: DaemonConnectionChannel(
        connection: liveConnection, mode: .v2(version: 2), clientID: liveClientID))
    _ = await registry.apply(.openProject(path: path), connectionID: liveConnection.id)
    let liveNode = UUID()
    _ = try await uploadThroughRegistry(
      registry, connectionID: liveConnection.id, projectPath: path, nodeID: liveNode,
      data: Data("expires".utf8))
    await fixture.setRemoveFailures(4)
    clock.advance(RemoteAssetStore.finalizedDraftLifetime + 1)
    let expired = await assets.resourceUsage()
    XCTAssertEqual(expired.finalizedDrafts, 0)
    XCTAssertEqual(expired.finalizedAttachments, 0)
    XCTAssertEqual(expired.finalizedBytes, 0)
    XCTAssertEqual(expired.pendingDraftCleanups, 1)
    let pendingFile = await fixture.stagedData(
      path: path, nodeID: liveNode, name: "image-1.png")
    XCTAssertNotNil(pendingFile)
    clock.advance(3)
    _ = await assets.resourceUsage()
    clock.advance(3)
    let retried = await assets.resourceUsage()
    XCTAssertEqual(retried.pendingDraftCleanups, 0)
    let cleanedFile = await fixture.stagedData(
      path: path, nodeID: liveNode, name: "image-1.png")
    XCTAssertNil(cleanedFile)
    XCTAssertEqual(
      retried,
      RemoteAssetUsageSnapshot(
        activeTransfers: 0, declaredBytes: 0, bufferedBytes: 0, pendingDeliveries: 0))
    XCTAssertFalse(liveConnection.sentFrames().isEmpty)
    await registry.removeConnection(liveConnection.id)
  }

  func testFinalizedDraftProjectAndGlobalCountLimitsAreAtomic() async throws {
    let projectFixture = Fixture()
    let projectStore = store(fixture: projectFixture)
    let path = "ssh://fixture/project-limit"
    var projectOwners: [UUID] = []
    for index in 0..<RemoteAssetStore.maximumFinalizedDraftsPerProject {
      let owner = UUID()
      projectOwners.append(owner)
      _ = try await uploadDraft(
        projectStore, owner: owner, projectPath: path, metadata: .ssh, nodeID: UUID(),
        name: "project-\(index).png", data: Data([1]))
    }
    let projectOverflowOwner = UUID()
    let projectOverflow = try await projectStore.beginUpload(
      owner: projectOverflowOwner, projectPath: path, metadata: .ssh, nodeID: UUID(),
      declaration: declaration(name: "project-over.png", data: Data([1])), existingCount: 0
    ).get()
    _ = try await projectStore.append(
      owner: projectOverflowOwner, transferID: projectOverflow.transferID, offset: 0,
      data: Data([1])
    ).get()
    guard
      case .failure(.resourceExhausted) = await projectStore.finalize(
        owner: projectOverflowOwner, transferID: projectOverflow.transferID)
    else {
      return XCTFail("expected project finalized draft limit")
    }
    let projectUsage = await projectStore.resourceUsage()
    XCTAssertEqual(
      projectUsage.finalizedDrafts, RemoteAssetStore.maximumFinalizedDraftsPerProject)
    for owner in projectOwners {
      await projectStore.disconnected(owner: owner)
    }
    let releasedProjectUsage = await projectStore.resourceUsage()
    XCTAssertEqual(releasedProjectUsage.finalizedDrafts, 0)

    let globalFixture = Fixture()
    let globalStore = store(fixture: globalFixture)
    var globalOwners: [UUID] = []
    for index in 0..<RemoteAssetStore.maximumFinalizedDraftsGlobal {
      let owner = UUID()
      globalOwners.append(owner)
      _ = try await uploadDraft(
        globalStore, owner: owner, projectPath: "ssh://fixture/global-\(index)",
        metadata: .ssh, nodeID: UUID(), name: "global.png", data: Data([1]))
    }
    let globalOverflowOwner = UUID()
    let globalOverflow = try await globalStore.beginUpload(
      owner: globalOverflowOwner, projectPath: "ssh://fixture/global-over", metadata: .ssh,
      nodeID: UUID(), declaration: declaration(name: "global-over.png", data: Data([1])),
      existingCount: 0
    ).get()
    _ = try await globalStore.append(
      owner: globalOverflowOwner, transferID: globalOverflow.transferID, offset: 0,
      data: Data([1])
    ).get()
    guard
      case .failure(.resourceExhausted) = await globalStore.finalize(
        owner: globalOverflowOwner, transferID: globalOverflow.transferID)
    else {
      return XCTFail("expected global finalized draft limit")
    }
    let globalUsage = await globalStore.resourceUsage()
    XCTAssertEqual(globalUsage.finalizedDrafts, RemoteAssetStore.maximumFinalizedDraftsGlobal)
    for owner in globalOwners {
      await globalStore.disconnected(owner: owner)
    }
    let releasedGlobalUsage = await globalStore.resourceUsage()
    XCTAssertEqual(
      releasedGlobalUsage,
      RemoteAssetUsageSnapshot(
        activeTransfers: 0, declaredBytes: 0, bufferedBytes: 0, pendingDeliveries: 0))
  }

  func testFinalizedDraftExpiresWhileLogicalClientSocketRemainsPassive() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-passive-expiry-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture()
    let assets = store(fixture: fixture, finalizedDraftLifetime: 0.05)
    let path = "ssh://fixture/passive-expiry"
    let registry = ProjectRegistry(
      persistenceDirectory: root, remoteAssets: assets,
      ensureSession: nil, terminateSession: nil, restartSession: nil,
      persistsSynchronously: true, classifyProject: { _ in .ssh })
    let connection = RemoteAssetTestConnection(peerProcessID: 7_101)
    await registry.addConnection(
      id: connection.id,
      channel: DaemonConnectionChannel(
        connection: connection, mode: .v2(version: 2), clientID: UUID()))
    _ = await registry.apply(.openProject(path: path), connectionID: connection.id)
    let nodeID = UUID()
    _ = try await uploadThroughRegistry(
      registry, connectionID: connection.id, projectPath: path, nodeID: nodeID,
      data: Data("passive".utf8))

    try await Task.sleep(for: .milliseconds(150))

    let staged = await fixture.stagedData(path: path, nodeID: nodeID, name: "image-1.png")
    XCTAssertNil(staged)
    XCTAssertFalse(connection.sentFrames().isEmpty)
    let usage = await assets.resourceUsage()
    XCTAssertEqual(
      usage,
      RemoteAssetUsageSnapshot(
        activeTransfers: 0, declaredBytes: 0, bufferedBytes: 0, pendingDeliveries: 0))
    await registry.removeConnection(connection.id)
  }

  func testGraphRejectionRollsBackOnlyDraftFilesAndRetriesCleanup() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-graph-rejection-\(UUID())", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture()
    let assets = store(fixture: fixture)
    let registry = ProjectRegistry(
      persistenceDirectory: root.appendingPathComponent("state"), remoteAssets: assets,
      ensureSession: nil, terminateSession: nil, restartSession: nil,
      persistsSynchronously: true, classifyProject: { _ in .local })
    let clientID = UUID()
    let connection = RemoteAssetTestConnection(peerProcessID: 8_001)
    await registry.addConnection(
      id: connection.id,
      channel: DaemonConnectionChannel(
        connection: connection, mode: .v2(version: 2), clientID: clientID))
    _ = await registry.apply(.openProject(path: project.path), connectionID: connection.id)

    let nodeID = UUID()
    let existing = Data("existing".utf8)
    _ = await fixture.stage(
      path: project.path, nodeID: nodeID, name: "existing.png", data: existing)
    let attachment = try await uploadThroughRegistry(
      registry, connectionID: connection.id, projectPath: project.path, nodeID: nodeID,
      data: Data("rollback".utf8))
    await fixture.setRemoveFailures(4)
    let rejected = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(
            id: nodeID, title: "Rejected", loopType: .turnBased, firstInstruction: "   ",
            attachments: [attachment]))),
      connectionID: connection.id)
    XCTAssertNotNil(rejected?.error)
    XCTAssertNil(rejected?.response)
    XCTAssertFalse(
      ProjectPersistence(baseDirectory: root.appendingPathComponent("state"))
        .loadGraph(path: project.path)?.nodesAtAnyDepth.contains(where: { $0.id == nodeID })
        ?? false)
    let pending = await assets.resourceUsage()
    XCTAssertEqual(pending.finalizedDrafts, 0)
    XCTAssertEqual(pending.pendingDraftCleanups, 0)
    let existingAfter = await fixture.stagedData(
      path: project.path, nodeID: nodeID, name: "existing.png")
    let draftAfter = await fixture.stagedData(
      path: project.path, nodeID: nodeID, name: attachment.fileName)
    XCTAssertEqual(existingAfter, existing)
    XCTAssertNil(draftAfter)
    await registry.removeConnection(connection.id)
  }

  func testNestedCreateAppliesAttachmentTransactionAtArbitraryDepth() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-nested-create-\(UUID())", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture()
    let assets = store(
      fixture: fixture,
      attachmentsDirectory: { _, nodeID in
        staging.appendingPathComponent(nodeID.uuidString, isDirectory: true)
      })
    let state = root.appendingPathComponent("state")
    let outerID = UUID()
    let innerID = UUID()
    let nestedProject = ProjectRef(path: project.path, name: "Nested", metadata: .local)
    let innerGraph = LoopGraph(project: nestedProject)
    let outerGraph = LoopGraph(
      project: nestedProject,
      nodes: [LoopNode(id: innerID, title: "Inner", loopType: .composite, subGraph: innerGraph)])
    ProjectPersistence(baseDirectory: state).saveGraph(
      LoopGraph(
        project: ProjectRef(path: project.path, name: "Project", metadata: .local),
        nodes: [
          LoopNode(id: outerID, title: "Outer", loopType: .composite, subGraph: outerGraph)
        ]))
    let registry = ProjectRegistry(
      persistenceDirectory: state,
      remoteAssets: assets,
      ensureSession: nil,
      terminateSession: nil,
      restartSession: nil,
      persistsSynchronously: true,
      classifyProject: { _ in .local })
    let peerProcessID: UInt64 = 7_777
    let logicalClientID = UUID()
    let upload = RemoteAssetTestConnection(peerProcessID: peerProcessID)
    let graph = RemoteAssetTestConnection(peerProcessID: peerProcessID)
    await registry.addConnection(
      id: upload.id,
      channel: DaemonConnectionChannel(
        connection: upload, mode: .v2(version: 2), clientID: logicalClientID))
    await registry.addConnection(
      id: graph.id, channel: DaemonConnectionChannel(connection: graph, mode: .v1))
    _ = await registry.apply(
      .announce(capabilities: [], clientID: logicalClientID), connectionID: graph.id)
    _ = await registry.apply(.openProject(path: project.path), connectionID: upload.id)
    _ = await registry.apply(.openProject(path: project.path), connectionID: graph.id)

    let childID = UUID()
    let childData = Data("nested opaque".utf8)
    let attachment = try await uploadThroughRegistry(
      registry, connectionID: upload.id, projectPath: project.path, nodeID: childID,
      data: childData)
    await registry.removeConnection(upload.id)
    let nestedCreate = GraphCommand.subGraphCommand(
      nodeID: outerID,
      command: .subGraphCommand(
        nodeID: innerID,
        command: .createNode(
          NodeDraft(
            id: childID, title: "Nested child", loopType: .turnBased,
            firstInstruction: "work", attachments: [attachment]))))
    let created = await registry.apply(
      .graphCommand(projectPath: project.path, command: nestedCreate),
      connectionID: graph.id)
    XCTAssertNil(created?.error)
    guard case .graphChanged(let graphSnapshot) = created?.response else {
      return XCTFail("expected nested graph snapshot")
    }
    XCTAssertEqual(
      graphSnapshot.nodes[id: outerID]?.subGraph?.nodes[id: innerID]?.subGraph?.nodes[id: childID]?
        .attachments,
      [attachment])

    let privateID = UUID()
    let privatePath = root.appendingPathComponent("private.png")
    try Data("private".utf8).write(to: privatePath)
    let invalid = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .subGraphCommand(
          nodeID: innerID,
          command: .createNode(
            NodeDraft(
              id: privateID, title: "Private", loopType: .turnBased,
              firstInstruction: "work",
              attachments: [PromptAttachment(path: privatePath.path, name: "private.png")])))),
      connectionID: graph.id)
    XCTAssertEqual(invalid?.errorCode, .remoteAssetInvalidReference)

    let legacyID = UUID()
    let legacyDirectory = staging.appendingPathComponent(legacyID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
    let legacyFile = legacyDirectory.appendingPathComponent("legacy.png")
    let legacyData = Data("legacy".utf8)
    try legacyData.write(to: legacyFile)
    _ = await fixture.stage(
      path: project.path, nodeID: legacyID, name: "legacy.png", data: legacyData)
    let legacy = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .subGraphCommand(
          nodeID: innerID,
          command: .createNode(
            NodeDraft(
              id: legacyID, title: "Legacy", loopType: .turnBased,
              firstInstruction: "work",
              attachments: [PromptAttachment(path: legacyFile.path, name: "legacy.png")])))),
      connectionID: graph.id)
    XCTAssertNil(legacy?.error)

    let duplicate = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .subGraphCommand(
          nodeID: innerID,
          command: .createNode(
            NodeDraft(
              id: childID, title: "Duplicate", loopType: .turnBased,
              firstInstruction: "work")))),
      connectionID: graph.id)
    XCTAssertNotNil(duplicate?.error)

    let rejectedID = UUID()
    let rejectedData = Data("reject me".utf8)
    let replacementUpload = RemoteAssetTestConnection(peerProcessID: peerProcessID)
    await registry.addConnection(
      id: replacementUpload.id,
      channel: DaemonConnectionChannel(
        connection: replacementUpload, mode: .v2(version: 2), clientID: logicalClientID))
    _ = await registry.apply(.openProject(path: project.path), connectionID: replacementUpload.id)
    _ = try await uploadThroughRegistry(
      registry, connectionID: replacementUpload.id, projectPath: project.path,
      nodeID: rejectedID, data: rejectedData)
    let rejected = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .subGraphCommand(
          nodeID: UUID(),
          command: .createNode(
            NodeDraft(
              id: rejectedID, title: "Rejected", loopType: .turnBased,
              firstInstruction: "work")))),
      connectionID: graph.id)
    XCTAssertNotNil(rejected?.error)
    let rejectedStaged = await fixture.stagedData(
      path: project.path, nodeID: rejectedID, name: "image-1.png")
    XCTAssertNil(rejectedStaged)
  }

  func testProductionLocalLeaseRejectsReplacementLinksAndPreservesExistingRetention() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-production-lease-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectPath = root.appendingPathComponent("project", isDirectory: true).path
    let nodeID = UUID()
    let original = Data("original".utf8)
    let descriptor = RemoteAssetRetentionDescriptor(
      name: "image.png", size: original.count,
      sha256: RemoteAssetDigest.sha256Hex(original))
    let directory = NodeMemory.attachmentsDirectory(
      forProjectPath: projectPath, nodeID: nodeID)
    defer { LocalRemoteAssetHost.discardAttachments(projectPath: projectPath, nodeID: nodeID) }

    _ = try LocalRemoteAssetHost.stageAttachment(
      projectPath: projectPath, nodeID: nodeID, name: descriptor.name, data: original)
    let leaseID = UUID()
    try LocalRemoteAssetHost.acquireAttachmentLease(
      projectPath: projectPath, nodeID: nodeID, leaseID: leaseID, descriptors: [descriptor])
    try Data("replaced".utf8).write(to: directory.appendingPathComponent(descriptor.name))
    try LocalRemoteAssetHost.verifyAttachmentLease(
      projectPath: projectPath, nodeID: nodeID, leaseID: leaseID, descriptors: [descriptor])
    try LocalRemoteAssetHost.commitAttachmentLease(
      projectPath: projectPath, nodeID: nodeID, leaseID: leaseID, descriptors: [descriptor])
    let retainedPath = try LocalRemoteAssetHost.resolveAttachment(
      projectPath: projectPath, nodeID: nodeID, name: descriptor.name,
      size: descriptor.size, sha256: descriptor.sha256)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: retainedPath)), original)

    let racedNode = UUID()
    defer {
      LocalRemoteAssetHost.discardAttachments(projectPath: projectPath, nodeID: racedNode)
    }
    _ = try LocalRemoteAssetHost.stageAttachment(
      projectPath: projectPath, nodeID: racedNode, name: descriptor.name, data: original)
    let racedLease = UUID()
    try LocalRemoteAssetHost.acquireAttachmentLease(
      projectPath: projectPath, nodeID: racedNode, leaseID: racedLease,
      descriptors: [descriptor])
    try LocalRemoteAssetHost.verifyAttachmentLease(
      projectPath: projectPath, nodeID: racedNode, leaseID: racedLease,
      descriptors: [descriptor])
    let racedPath = NodeMemory.attachmentsDirectory(
      forProjectPath: projectPath, nodeID: racedNode
    ).appendingPathComponent(".leases").appendingPathComponent(racedLease.uuidString)
      .appendingPathComponent(descriptor.name)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: racedPath.path)
    try FileManager.default.removeItem(at: racedPath)
    try Data("tampered".utf8).write(to: racedPath)
    XCTAssertThrowsError(
      try LocalRemoteAssetHost.verifyAttachmentLease(
        projectPath: projectPath, nodeID: racedNode, leaseID: racedLease,
        descriptors: [descriptor]))
    XCTAssertThrowsError(
      try LocalRemoteAssetHost.rollbackAttachmentLease(
        projectPath: projectPath, nodeID: racedNode, leaseID: racedLease,
        descriptors: [descriptor]))
    XCTAssertEqual(
      try Data(
        contentsOf: URL(
          fileURLWithPath: LocalRemoteAssetHost.resolveAttachment(
            projectPath: projectPath, nodeID: nodeID, name: descriptor.name,
            size: descriptor.size, sha256: descriptor.sha256))),
      original)

    let linkedNode = UUID()
    defer {
      LocalRemoteAssetHost.discardAttachments(projectPath: projectPath, nodeID: linkedNode)
    }
    let linkedDirectory = NodeMemory.attachmentsDirectory(
      forProjectPath: projectPath, nodeID: linkedNode)
    try FileManager.default.createDirectory(
      at: linkedDirectory, withIntermediateDirectories: true)
    let linkedSource = linkedDirectory.appendingPathComponent(descriptor.name)
    try original.write(to: linkedSource)
    let linkedAlias = linkedDirectory.appendingPathComponent("alias.png")
    #if os(Windows)
      var sourcePath = Array(linkedSource.path.utf16)
      sourcePath.append(0)
      var aliasPath = Array(linkedAlias.path.utf16)
      aliasPath.append(0)
      let linked = sourcePath.withUnsafeBufferPointer { source in
        aliasPath.withUnsafeBufferPointer { alias in
          CreateHardLinkW(alias.baseAddress, source.baseAddress, nil)
        }
      }
      XCTAssertTrue(linked)
    #else
      try FileManager.default.linkItem(at: linkedSource, to: linkedAlias)
    #endif
    XCTAssertThrowsError(
      try LocalRemoteAssetHost.acquireAttachmentLease(
        projectPath: projectPath, nodeID: linkedNode, leaseID: UUID(),
        descriptors: [descriptor]))

    let symbolicNode = UUID()
    defer {
      LocalRemoteAssetHost.discardAttachments(projectPath: projectPath, nodeID: symbolicNode)
    }
    let symbolicDirectory = NodeMemory.attachmentsDirectory(
      forProjectPath: projectPath, nodeID: symbolicNode)
    try FileManager.default.createDirectory(
      at: symbolicDirectory, withIntermediateDirectories: true)
    let external = root.appendingPathComponent("external.png")
    try original.write(to: external)
    let symbolic = symbolicDirectory.appendingPathComponent(descriptor.name)
    if (try? FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: external))
      != nil
    {
      XCTAssertThrowsError(
        try LocalRemoteAssetHost.acquireAttachmentLease(
          projectPath: projectPath, nodeID: symbolicNode, leaseID: UUID(),
          descriptors: [descriptor]))
    }

    let duplicateNode = UUID()
    defer {
      LocalRemoteAssetHost.discardAttachments(projectPath: projectPath, nodeID: duplicateNode)
    }
    let secondDescriptor = RemoteAssetRetentionDescriptor(
      name: "second.png", size: original.count, sha256: descriptor.sha256)
    _ = try LocalRemoteAssetHost.stageAttachment(
      projectPath: projectPath, nodeID: duplicateNode, name: descriptor.name, data: original)
    _ = try LocalRemoteAssetHost.stageAttachment(
      projectPath: projectPath, nodeID: duplicateNode, name: secondDescriptor.name, data: original)
    let duplicateLease = UUID()
    try LocalRemoteAssetHost.acquireAttachmentLease(
      projectPath: projectPath, nodeID: duplicateNode, leaseID: duplicateLease,
      descriptors: [descriptor, secondDescriptor])
    try LocalRemoteAssetHost.commitAttachmentLease(
      projectPath: projectPath, nodeID: duplicateNode, leaseID: duplicateLease,
      descriptors: [descriptor, secondDescriptor])
    let duplicateLeasePath = NodeMemory.attachmentsDirectory(
      forProjectPath: projectPath, nodeID: duplicateNode
    ).appendingPathComponent(".leases").appendingPathComponent(duplicateLease.uuidString)
    XCTAssertFalse(FileManager.default.fileExists(atPath: duplicateLeasePath.path))

    let swappedNode = UUID()
    defer {
      LocalRemoteAssetHost.discardAttachments(projectPath: projectPath, nodeID: swappedNode)
    }
    _ = try LocalRemoteAssetHost.stageAttachment(
      projectPath: projectPath, nodeID: swappedNode, name: descriptor.name, data: original)
    let swappedLease = UUID()
    try LocalRemoteAssetHost.acquireAttachmentLease(
      projectPath: projectPath, nodeID: swappedNode, leaseID: swappedLease,
      descriptors: [descriptor])
    let swappedRoot = NodeMemory.attachmentsDirectory(
      forProjectPath: projectPath, nodeID: swappedNode)
    let swappedLeasePath = swappedRoot.appendingPathComponent(".leases")
      .appendingPathComponent(swappedLease.uuidString)
    let hiddenLease = swappedRoot.appendingPathComponent(".hidden-lease")
    try FileManager.default.moveItem(at: swappedLeasePath, to: hiddenLease)
    let victim = root.appendingPathComponent("victim", isDirectory: true)
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    let victimFile = victim.appendingPathComponent(descriptor.name)
    try original.write(to: victimFile)
    if (try? FileManager.default.createSymbolicLink(
      at: swappedLeasePath, withDestinationURL: victim)) != nil
    {
      XCTAssertThrowsError(
        try LocalRemoteAssetHost.rollbackAttachmentLease(
          projectPath: projectPath, nodeID: swappedNode, leaseID: swappedLease,
          descriptors: [descriptor]))
      XCTAssertEqual(try Data(contentsOf: victimFile), original)
    }
  }

  func testReplacementBeforeAndAfterLeaseVerificationNeverPublishesGraph() async throws {
    for corruptAfterVerification in [false, true] {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("asset-content-race-\(UUID())", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let fixture = Fixture()
      let assets = store(fixture: fixture)
      let registry = ProjectRegistry(
        persistenceDirectory: root, remoteAssets: assets,
        ensureSession: nil, terminateSession: nil, restartSession: nil,
        persistsSynchronously: true, classifyProject: { _ in .ssh })
      let connection = RemoteAssetTestConnection()
      await registry.addConnection(
        id: connection.id,
        channel: DaemonConnectionChannel(
          connection: connection, mode: .v2(version: 2), clientID: UUID()))
      let path = "ssh://fixture/content-race-\(corruptAfterVerification)"
      _ = await registry.apply(.openProject(path: path), connectionID: connection.id)
      let nodeID = UUID()
      let original = Data("content-a".utf8)
      let attachment = try await uploadThroughRegistry(
        registry, connectionID: connection.id, projectPath: path, nodeID: nodeID,
        data: original)
      if corruptAfterVerification {
        await fixture.corruptNextLeaseAfterVerify(with: Data("content-b".utf8))
      } else {
        await fixture.replaceStaged(
          path: path, nodeID: nodeID, name: attachment.fileName,
          data: Data("content-b".utf8))
      }
      let result = await registry.apply(
        .graphCommand(
          projectPath: path,
          command: .createNode(
            NodeDraft(
              id: nodeID, title: "Must not persist", loopType: .turnBased,
              firstInstruction: "work", attachments: [attachment]))),
        connectionID: connection.id)
      XCTAssertNotNil(result?.error)
      XCTAssertNil(result?.response)
      XCTAssertFalse(
        ProjectPersistence(baseDirectory: root).loadGraph(path: path)?
          .nodesAtAnyDepth.contains(where: { $0.id == nodeID }) ?? false)
      await registry.removeConnection(connection.id)
    }
  }

  func testDurableCatalogRestoresQuotaLeaseRecoveryAndOmitsHostPaths() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-catalog-recovery-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = root.appendingPathComponent("catalog.json")
    let fixture = Fixture()
    let owner = UUID()
    let path = "ssh://fixture/private-host/project"
    let nodeID = UUID()
    let bytes = Data("catalog-secret-content".utf8)
    let first = store(fixture: fixture, catalogURL: catalog)
    let attachment = try await uploadDraft(
      first, owner: owner, projectPath: path, metadata: .ssh, nodeID: nodeID,
      data: bytes)
    let catalogText = String(decoding: try Data(contentsOf: catalog), as: UTF8.self)
    XCTAssertFalse(catalogText.contains(path))
    XCTAssertFalse(catalogText.contains(String(decoding: bytes, as: UTF8.self)))

    let restored = store(fixture: fixture, catalogURL: catalog)
    let restoredUsage = await restored.resourceUsage()
    XCTAssertEqual(restoredUsage.finalizedDrafts, 1)
    let preparedLease = try await restored.prepareCreate(
      [attachment], owner: owner, projectPath: path, metadata: .ssh, nodeID: nodeID,
      allowsLegacyLocalPaths: false
    ).get()
    let leaseID = try XCTUnwrap(preparedLease)

    let graphPersistedRecovery = store(fixture: fixture, catalogURL: catalog)
    await graphPersistedRecovery.reconcile(
      projectPath: path, metadata: .ssh, graphNodeIDs: [nodeID])
    let recoveredUsage = await graphPersistedRecovery.resourceUsage()
    let recoveredData = await fixture.stagedData(
      path: path, nodeID: nodeID, name: attachment.fileName)
    XCTAssertEqual(recoveredUsage.finalizedDrafts, 0)
    XCTAssertEqual(recoveredData, bytes)
    _ = leaseID

    let rollbackNode = UUID()
    let rollbackAttachment = try await uploadDraft(
      graphPersistedRecovery, owner: owner, projectPath: path, metadata: .ssh,
      nodeID: rollbackNode, name: "rollback.png", data: Data("rollback".utf8))
    let rollbackLease = try await graphPersistedRecovery.prepareCreate(
      [rollbackAttachment], owner: owner, projectPath: path, metadata: .ssh,
      nodeID: rollbackNode, allowsLegacyLocalPaths: false
    ).get()
    _ = try XCTUnwrap(rollbackLease)
    let graphRejectedRecovery = store(fixture: fixture, catalogURL: catalog)
    await graphRejectedRecovery.reconcile(
      projectPath: path, metadata: .ssh, graphNodeIDs: [nodeID])
    let rolledBackData = await fixture.stagedData(
      path: path, nodeID: rollbackNode, name: rollbackAttachment.fileName)
    let rolledBackUsage = await graphRejectedRecovery.resourceUsage()
    XCTAssertNil(rolledBackData)
    XCTAssertEqual(rolledBackUsage.finalizedDrafts, 0)
  }

  func testLegacyV1LocalCreatePersistsOpaqueContentBoundAttachment() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-legacy-production-\(UUID())", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let nodeID = UUID()
    defer {
      LocalRemoteAssetHost.discardAttachments(projectPath: project.path, nodeID: nodeID)
    }
    let bytes = Data("legacy-production".utf8)
    let path = try LocalRemoteAssetHost.stageAttachment(
      projectPath: project.path, nodeID: nodeID, name: "legacy.png", data: bytes)
    let assets = RemoteAssetStore(
      transport: .live, authenticationKey: Data(repeating: 0x71, count: 32),
      catalogURL: root.appendingPathComponent("remote-assets.json"))
    let registry = ProjectRegistry(
      persistenceDirectory: root.appendingPathComponent("state"), remoteAssets: assets,
      ensureSession: nil, terminateSession: nil, restartSession: nil,
      persistsSynchronously: true, classifyProject: { _ in .local })
    let connection = RemoteAssetTestConnection()
    await registry.addConnection(
      id: connection.id,
      channel: DaemonConnectionChannel(connection: connection, mode: .v1))
    _ = await registry.apply(.openProject(path: project.path), connectionID: connection.id)
    let result = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(
            id: nodeID, title: "Legacy", loopType: .turnBased,
            firstInstruction: "work",
            attachments: [PromptAttachment(path: path, name: "legacy.png")]))),
      connectionID: connection.id)
    XCTAssertNil(result?.error)
    guard case .graphChanged(let graph) = result?.response,
      let secured = graph.nodesAtAnyDepth.first(where: { $0.id == nodeID })?.attachments.first
    else { return XCTFail("expected persisted legacy node") }
    XCTAssertTrue(secured.isOpaqueReference)
    let resolved = try await assets.resolvedPath(
      for: secured, projectPath: project.path, nodeID: nodeID, metadata: .local
    ).get()
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: resolved)), bytes)
    await registry.removeConnection(connection.id)
  }

  func testDurableCleanupRecoversAfterOutageAndReportsTerminalQuarantine() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-cleanup-recovery-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = root.appendingPathComponent("catalog.json")
    let fixture = Fixture()
    let clock = RemoteAssetTestClock(Date(timeIntervalSince1970: 10_000))
    let owner = UUID()
    let path = "codespace://fixture/cleanup"

    var first: RemoteAssetStore? = store(
      fixture: fixture, now: { clock.now() }, catalogURL: catalog)
    let firstNode = UUID()
    let firstData = Data("eventual-cleanup".utf8)
    let firstTicket = try await first!.beginUpload(
      owner: owner, projectPath: path, metadata: .codespace, nodeID: firstNode,
      declaration: declaration(data: firstData), existingCount: 0
    ).get()
    _ = try await first!.append(
      owner: owner, transferID: firstTicket.transferID, offset: 0, data: firstData
    ).get()
    _ = try await first!.finalize(owner: owner, transferID: firstTicket.transferID).get()
    await fixture.setRemoveFailures(20)
    let firstCleanup = await first!.completeDelivery(
      owner: owner, deliveryID: firstTicket.transferID, delivered: false)
    XCTAssertThrowsError(try firstCleanup.get())
    let pendingUsage = await first!.resourceUsage()
    XCTAssertEqual(pendingUsage.pendingDraftCleanups, 1)
    first = nil

    await fixture.setRemoveFailures(0)
    clock.advance(10)
    let recovered = store(fixture: fixture, now: { clock.now() }, catalogURL: catalog)
    await recovered.reconcile(projectPath: path, metadata: .codespace, graphNodeIDs: [])
    let recoveredUsage = await recovered.resourceUsage()
    XCTAssertEqual(recoveredUsage.pendingDraftCleanups, 0)
    let recoveredFile = await fixture.stagedData(
      path: path, nodeID: firstNode, name: "image-1.png")
    XCTAssertNil(recoveredFile)

    let quarantinedNode = UUID()
    let quarantinedData = Data("terminal-cleanup".utf8)
    let quarantinedTicket = try await recovered.beginUpload(
      owner: owner, projectPath: path, metadata: .codespace, nodeID: quarantinedNode,
      declaration: declaration(name: "terminal.png", data: quarantinedData), existingCount: 0
    ).get()
    _ = try await recovered.append(
      owner: owner, transferID: quarantinedTicket.transferID, offset: 0,
      data: quarantinedData
    ).get()
    _ = try await recovered.finalize(
      owner: owner, transferID: quarantinedTicket.transferID
    ).get()
    await fixture.setRemoveFailures(100)
    let terminalCleanup = await recovered.completeDelivery(
      owner: owner, deliveryID: quarantinedTicket.transferID, delivered: false)
    XCTAssertThrowsError(try terminalCleanup.get())
    for _ in 0..<RemoteAssetStore.maximumCleanupAttempts {
      clock.advance(4_000)
      _ = await recovered.resourceUsage()
    }
    let terminal = await recovered.resourceUsage()
    XCTAssertEqual(terminal.pendingDraftCleanups, 0)
    XCTAssertEqual(terminal.quarantinedDraftCleanups, 1)

    let restarted = store(fixture: fixture, now: { clock.now() }, catalogURL: catalog)
    await restarted.reconcile(projectPath: path, metadata: .codespace, graphNodeIDs: [])
    let restartedUsage = await restarted.resourceUsage()
    XCTAssertEqual(restartedUsage.quarantinedDraftCleanups, 1)
    let quarantinedFile = await fixture.stagedData(
      path: path, nodeID: quarantinedNode, name: "terminal.png")
    XCTAssertNotNil(quarantinedFile)
  }

  func testCreateAndDeleteWaitForAcknowledgedGraphPersistence() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-persistence-barrier-\(UUID())", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let state = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture()
    let assets = store(fixture: fixture)
    let replay = DaemonReplayStore()
    let failure = RemoteAssetPersistenceFailure()
    let registry = ProjectRegistry(
      persistenceDirectory: state, replayStore: replay, remoteAssets: assets,
      ensureSession: nil, terminateSession: nil, restartSession: nil,
      persistsSynchronously: true,
      beforeGraphWrite: { _ in try failure.check() },
      beforeGraphDelete: { _ in try failure.check() },
      classifyProject: { _ in .local })
    let clientID = UUID()
    let connection = RemoteAssetTestConnection()
    await registry.addConnection(
      id: connection.id,
      channel: DaemonConnectionChannel(
        connection: connection, mode: .v2(version: 2), clientID: clientID,
        replayStore: replay))
    _ = await registry.apply(.openProject(path: project.path), connectionID: connection.id)

    let failedID = UUID()
    let failedBytes = Data("create-save-failure".utf8)
    let failedAttachment = try await uploadThroughRegistry(
      registry, connectionID: connection.id, projectPath: project.path, nodeID: failedID,
      data: failedBytes)
    let createFrames = connection.sentFrames().count
    let createReplay = (try? replay.replay(clientID: clientID, after: 0).count) ?? 0
    failure.setFailing(true)
    let failedCreate = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(
            id: failedID, title: "Not durable", loopType: .turnBased,
            firstInstruction: "work", attachments: [failedAttachment]))),
      connectionID: connection.id)
    XCTAssertNil(failedCreate?.response)
    XCTAssertTrue(failedCreate?.error?.contains("graph persistence failed") == true)
    XCTAssertEqual(connection.sentFrames().count, createFrames)
    XCTAssertEqual(
      (try? replay.replay(clientID: clientID, after: 0).count) ?? 0, createReplay)
    XCTAssertFalse(
      ProjectPersistence(baseDirectory: state).loadGraph(path: project.path)?
        .nodesAtAnyDepth.contains(where: { $0.id == failedID }) ?? false)
    let failedStaged = await fixture.stagedData(
      path: project.path, nodeID: failedID, name: failedAttachment.fileName)
    XCTAssertNil(failedStaged)

    failure.setFailing(false)
    let durableID = UUID()
    let durableBytes = Data("delete-save-failure".utf8)
    let durableAttachment = try await uploadThroughRegistry(
      registry, connectionID: connection.id, projectPath: project.path, nodeID: durableID,
      data: durableBytes)
    let created = await registry.apply(
      .graphCommand(
        projectPath: project.path,
        command: .createNode(
          NodeDraft(
            id: durableID, title: "Durable", loopType: .turnBased,
            firstInstruction: "work", attachments: [durableAttachment]))),
      connectionID: connection.id)
    XCTAssertNil(created?.error)
    let deleteFrames = connection.sentFrames().count
    let deleteReplay = (try? replay.replay(clientID: clientID, after: 0).count) ?? 0
    failure.setFailing(true)
    let failedDelete = await registry.apply(
      .graphCommand(projectPath: project.path, command: .deleteNode(durableID)),
      connectionID: connection.id)
    XCTAssertNil(failedDelete?.response)
    XCTAssertTrue(failedDelete?.error?.contains("graph persistence failed") == true)
    XCTAssertEqual(connection.sentFrames().count, deleteFrames)
    XCTAssertEqual(
      (try? replay.replay(clientID: clientID, after: 0).count) ?? 0, deleteReplay)
    XCTAssertTrue(
      ProjectPersistence(baseDirectory: state).loadGraph(path: project.path)?
        .nodesAtAnyDepth.contains(where: { $0.id == durableID }) ?? false)
    let durableStaged = await fixture.stagedData(
      path: project.path, nodeID: durableID, name: durableAttachment.fileName)
    XCTAssertEqual(durableStaged, durableBytes)
    let failedProjectDelete = await registry.apply(
      .deleteProjectGraph(path: project.path), connectionID: connection.id)
    XCTAssertNil(failedProjectDelete?.response)
    XCTAssertTrue(
      failedProjectDelete?.error?.contains("graph deletion persistence failed") == true)
    XCTAssertNotNil(ProjectPersistence(baseDirectory: state).loadGraph(path: project.path))
    let projectDeleteStaged = await fixture.stagedData(
      path: project.path, nodeID: durableID, name: durableAttachment.fileName)
    XCTAssertEqual(projectDeleteStaged, durableBytes)
    await registry.removeConnection(connection.id)
  }

  func testDescriptorBoundCleanupQuarantinesSameNameReplacement() async throws {
    let fixture = Fixture()
    let clock = RemoteAssetTestClock(Date(timeIntervalSince1970: 20_000))
    let assets = store(fixture: fixture, now: { clock.now() })
    let owner = UUID()
    let path = "ssh://fixture/replaced-cleanup"
    let nodeID = UUID()
    let original = Data("original-content".utf8)
    let replacement = Data("replacement-data".utf8)
    XCTAssertEqual(original.count, replacement.count)
    let ticket = try await assets.beginUpload(
      owner: owner, projectPath: path, metadata: .ssh, nodeID: nodeID,
      declaration: declaration(data: original), existingCount: 0
    ).get()
    _ = try await assets.append(
      owner: owner, transferID: ticket.transferID, offset: 0, data: original
    ).get()
    _ = try await assets.finalize(owner: owner, transferID: ticket.transferID).get()
    await fixture.setRemoveFailures(20)
    do {
      _ = try await assets.completeDelivery(
        owner: owner, deliveryID: ticket.transferID, delivered: false
      ).get()
      XCTFail("expected initial cleanup failure")
    } catch {}
    await fixture.replaceStaged(
      path: path, nodeID: nodeID, name: "image-1.png", data: replacement)
    for _ in 0..<RemoteAssetStore.maximumCleanupAttempts {
      clock.advance(4_000)
      _ = await assets.resourceUsage()
    }
    let replacedData = await fixture.stagedData(
      path: path, nodeID: nodeID, name: "image-1.png")
    XCTAssertEqual(replacedData, replacement)
    let usage = await assets.resourceUsage()
    XCTAssertEqual(usage.pendingDraftCleanups, 0)
    XCTAssertEqual(usage.quarantinedDraftCleanups, 1)
  }

  func testPartialRemoteCommitIsIdempotentAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-partial-commit-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = root.appendingPathComponent("catalog.json")
    let fixture = Fixture()
    let owner = UUID()
    let path = "codespace://fixture/partial-commit"
    let nodeID = UUID()
    let firstData = Data("first-file".utf8)
    let secondData = Data("second-file".utf8)
    var first: RemoteAssetStore? = store(fixture: fixture, catalogURL: catalog)
    let firstAttachment = try await uploadDraft(
      first!, owner: owner, projectPath: path, metadata: .codespace, nodeID: nodeID,
      name: "first.png", data: firstData)
    let secondTicket = try await first!.beginUpload(
      owner: owner, projectPath: path, metadata: .codespace, nodeID: nodeID,
      declaration: declaration(name: "second.png", data: secondData), existingCount: 1
    ).get()
    _ = try await first!.append(
      owner: owner, transferID: secondTicket.transferID, offset: 0, data: secondData
    ).get()
    let secondAttachment = try await finalize(
      first!, owner: owner, transferID: secondTicket.transferID)
    let preparedLeaseID = try await first!.prepareCreate(
      [firstAttachment, secondAttachment], owner: owner, projectPath: path,
      metadata: .codespace, nodeID: nodeID, allowsLegacyLocalPaths: false
    ).get()
    let leaseID = try XCTUnwrap(preparedLeaseID)
    await fixture.failCommit(after: 0)
    guard
      case .failure(.transportFailure) = await first!.finalizeCreate(
        leaseID: leaseID, retainedNames: ["first.png", "second.png"])
    else { return XCTFail("expected injected partial commit failure") }
    first = nil

    let recovered = store(fixture: fixture, catalogURL: catalog)
    await recovered.reconcile(
      projectPath: path, metadata: .codespace, graphNodeIDs: [nodeID])
    let committedFirst = await fixture.stagedData(
      path: path, nodeID: nodeID, name: "first.png")
    let committedSecond = await fixture.stagedData(
      path: path, nodeID: nodeID, name: "second.png")
    XCTAssertEqual(committedFirst, firstData)
    XCTAssertEqual(committedSecond, secondData)
    let usage = await recovered.resourceUsage()
    XCTAssertEqual(usage.finalizedDrafts, 0)
    XCTAssertEqual(usage.pendingDraftCleanups, 0)
  }

  func testNestedCascadeAndProjectDeletionCleanCompleteRemoteDelta() async throws {
    for metadata in [ProjectMetadata.ssh, .codespace] {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("asset-delete-delta-\(UUID())", isDirectory: true)
      let state = root.appendingPathComponent("state", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let path = "\(metadata.location.rawValue)://fixture/delete-\(UUID())"
      let compositeID = UUID()
      let project = ProjectRef(path: path, name: "Remote", metadata: metadata)
      ProjectPersistence(baseDirectory: state).saveGraph(
        LoopGraph(
          project: project,
          nodes: [
            LoopNode(
              id: compositeID, title: "Composite", loopType: .composite,
              subGraph: LoopGraph(project: project))
          ]))
      let fixture = Fixture()
      let assets = store(fixture: fixture)
      let registry = ProjectRegistry(
        persistenceDirectory: state, remoteAssets: assets,
        ensureSession: nil, terminateSession: nil, restartSession: nil,
        persistsSynchronously: true, classifyProject: { _ in metadata })
      let connection = RemoteAssetTestConnection()
      await registry.addConnection(
        id: connection.id,
        channel: DaemonConnectionChannel(
          connection: connection, mode: .v2(version: 2), clientID: UUID()))
      _ = await registry.apply(.openProject(path: path), connectionID: connection.id)

      func create(_ id: UUID, title: String, createdBy: UUID? = nil) async throws {
        let data = Data(title.utf8)
        let attachment = try await uploadThroughRegistry(
          registry, connectionID: connection.id, projectPath: path, nodeID: id,
          name: "\(title).png", data: data)
        let result = await registry.apply(
          .graphCommand(
            projectPath: path,
            command: .createNode(
              NodeDraft(
                id: id, title: title, loopType: .turnBased, firstInstruction: "work",
                createdBy: createdBy, attachments: [attachment]))),
          connectionID: connection.id)
        XCTAssertNil(result?.error)
      }

      let parentID = UUID()
      let childID = UUID()
      let survivorID = UUID()
      try await create(parentID, title: "parent")
      try await create(childID, title: "child", createdBy: parentID)
      try await create(survivorID, title: "survivor")
      let cascade = await registry.apply(
        .graphCommand(projectPath: path, command: .deleteNode(parentID)),
        connectionID: connection.id)
      XCTAssertNil(cascade?.error)
      _ = await assets.resourceUsage()
      let parentData = await fixture.stagedData(
        path: path, nodeID: parentID, name: "parent.png")
      let childData = await fixture.stagedData(
        path: path, nodeID: childID, name: "child.png")
      let survivorData = await fixture.stagedData(
        path: path, nodeID: survivorID, name: "survivor.png")
      XCTAssertNil(parentData)
      XCTAssertNil(childData)
      XCTAssertNotNil(survivorData)

      let nestedID = UUID()
      let nestedData = Data("nested".utf8)
      let nestedAttachment = try await uploadThroughRegistry(
        registry, connectionID: connection.id, projectPath: path, nodeID: nestedID,
        name: "nested.png", data: nestedData)
      let nestedCreate = await registry.apply(
        .graphCommand(
          projectPath: path,
          command: .subGraphCommand(
            nodeID: compositeID,
            command: .createNode(
              NodeDraft(
                id: nestedID, title: "Nested", loopType: .turnBased,
                firstInstruction: "work", attachments: [nestedAttachment])))),
        connectionID: connection.id)
      XCTAssertNil(nestedCreate?.error)
      let nestedDelete = await registry.apply(
        .graphCommand(
          projectPath: path,
          command: .subGraphCommand(
            nodeID: compositeID, command: .deleteNode(nestedID))),
        connectionID: connection.id)
      XCTAssertNil(nestedDelete?.error)
      _ = await assets.resourceUsage()
      let deletedNested = await fixture.stagedData(
        path: path, nodeID: nestedID, name: "nested.png")
      XCTAssertNil(deletedNested)

      let projectDelete = await registry.apply(
        .deleteProjectGraph(path: path), connectionID: connection.id)
      XCTAssertNil(projectDelete?.error)
      _ = await assets.resourceUsage()
      let deletedSurvivor = await fixture.stagedData(
        path: path, nodeID: survivorID, name: "survivor.png")
      XCTAssertNil(deletedSurvivor)
      XCTAssertNil(ProjectPersistence(baseDirectory: state).loadGraph(path: path))
      await registry.removeConnection(connection.id)
    }
  }

  func testStartupRecoversUnopenedProjectAndCatalogQuarantineStaysBounded() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("asset-startup-catalog-\(UUID())", isDirectory: true)
    let state = root.appendingPathComponent("state", isDirectory: true)
    let catalog = state.appendingPathComponent("remote-assets/catalog.json")
    try FileManager.default.createDirectory(
      at: catalog.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture()
    let clock = RemoteAssetTestClock(Date(timeIntervalSince1970: 30_000))
    let path = "ssh://fixture/unopened-recovery"
    let nodeID = UUID()
    let owner = UUID()
    var initial: RemoteAssetStore? = store(
      fixture: fixture, now: { clock.now() }, catalogURL: catalog)
    let data = Data("startup-cleanup".utf8)
    let ticket = try await initial!.beginUpload(
      owner: owner, projectPath: path, metadata: .ssh, nodeID: nodeID,
      declaration: declaration(data: data), existingCount: 0
    ).get()
    _ = try await initial!.append(
      owner: owner, transferID: ticket.transferID, offset: 0, data: data
    ).get()
    _ = try await initial!.finalize(owner: owner, transferID: ticket.transferID).get()
    await fixture.setRemoveFailures(10)
    do {
      _ = try await initial!.completeDelivery(
        owner: owner, deliveryID: ticket.transferID, delivered: false
      ).get()
      XCTFail("expected initial cleanup failure")
    } catch {}
    ProjectPersistence(baseDirectory: state).saveGraph(
      LoopGraph(project: ProjectRef(path: path, name: "Remote", metadata: .ssh)))
    initial = nil
    await fixture.setRemoveFailures(0)
    clock.advance(10)
    let recovered = store(fixture: fixture, now: { clock.now() }, catalogURL: catalog)
    let registry = ProjectRegistry(
      persistenceDirectory: state, remoteAssets: recovered,
      ensureSession: nil, terminateSession: nil, restartSession: nil,
      classifyProject: { _ in .ssh })
    for _ in 0..<100 {
      if await fixture.stagedData(path: path, nodeID: nodeID, name: "image-1.png") == nil {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let startupCleaned = await fixture.stagedData(
      path: path, nodeID: nodeID, name: "image-1.png")
    XCTAssertNil(startupCleaned)
    _ = registry

    for index in 0..<16 {
      if index == 0 {
        _ = FileManager.default.createFile(atPath: catalog.path, contents: nil)
        let handle = try FileHandle(forWritingTo: catalog)
        try handle.truncate(atOffset: UInt64(RemoteAssetStore.maximumCatalogBytes + 1))
        try handle.close()
      } else {
        try Data("{corrupt-\(index)".utf8).write(to: catalog, options: .atomic)
      }
      _ = store(fixture: fixture, catalogURL: catalog)
    }
    let quarantines = try FileManager.default.contentsOfDirectory(
      at: catalog.deletingLastPathComponent(),
      includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
    ).filter { $0.lastPathComponent.contains(".corrupt-") }
    XCTAssertLessThanOrEqual(
      quarantines.count, RemoteAssetStore.maximumCatalogQuarantineFiles)
    let quarantineBytes = try quarantines.reduce(0) {
      $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    XCTAssertLessThanOrEqual(
      quarantineBytes, RemoteAssetStore.maximumCatalogQuarantineBytes)
  }
}
