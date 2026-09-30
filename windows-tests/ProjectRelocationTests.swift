import Foundation
import GraphcodeKit
import Testing

private final class RelocationTestConnection: @unchecked Sendable, DaemonConnection {
  let id = UUID()
  let endpoint: DaemonEndpoint = .namedPipe("\\\\.\\pipe\\graphcode-relocation-test")
  private let lock = NSLock()
  private var sent: [Data] = []

  func receiveFrame() async throws -> Data { Data() }
  func sendFrame(_ data: Data) async throws {
    lock.withLock { sent.append(data) }
  }
  func close() async throws {}

  func frames() -> [Data] {
    lock.withLock { sent }
  }
}
@Suite
struct ProjectRelocationTests {
  private func fixture() throws -> (root: URL, support: URL, source: URL, destination: URL) {
    let tempRoot = URL(fileURLWithPath: "C:\\Temp", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let root =
      tempRoot
      .appendingPathComponent("gc-reloc-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: source.appendingPathComponent("tracked.txt"))
    return (root, support, source, destination)
  }

  @Test
  func sameVolumeRelocationMovesOnlySyntheticFixtureAndRekeysSupportState() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let persistence = ProjectPersistence(baseDirectory: fixture.support)
    let nested = LoopGraph(
      project: ProjectRef(path: fixture.source.path + "\\nested", name: "nested"))
    let node = LoopNode(
      id: UUID(), title: "Loop", loopType: .composite, subGraph: nested)
    let graph = LoopGraph(
      project: ProjectRef(path: fixture.source.path, name: "source", metadata: .local),
      nodes: [node])
    persistence.saveGraph(graph)
    let memoryLog = NodeMemory.logURL(
      forProjectPath: fixture.source.path, nodeID: node.id, baseURL: fixture.support)
    try FileManager.default.createDirectory(
      at: memoryLog.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("remember\n".utf8).write(to: memoryLog)
    persistence.recordOpened(graph.project)
    persistence.saveOpenProjects([fixture.source.path])

    let coordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
    let plan = try coordinator.prepare(
      sourcePath: fixture.source.path, destinationPath: fixture.destination.path,
      graphRevision: 7)
    let result = try coordinator.relocate(
      ProjectRelocationRequest(
        operationID: UUID(), sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        expectedSourceIdentity: plan.sourceIdentity, expectedGraphRevision: 7),
      graph: graph, persistence: persistence)

    #expect(result.destinationPath == fixture.destination.path)
    #expect(result.recoveryRequired == false)
    #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(persistence.loadGraph(path: fixture.source.path) == nil)
    let relocated = persistence.loadGraph(path: fixture.destination.path)
    #expect(relocated?.project.path == fixture.destination.path)
    #expect(relocated?.nodes.first?.subGraph?.project.path == fixture.destination.path)
    #expect(persistence.loadRecentProjects().map(\.path) == [fixture.destination.path])
    #expect(persistence.loadOpenProjects() == [fixture.destination.path])
    #expect(
      NodeMemory.entries(
        forProjectPath: fixture.destination.path, nodeID: node.id, baseURL: fixture.support
      ).contains(where: { $0.contains("remember") }))
  }

  @Test
  func identityChangeIsRejectedBeforeMutation() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let coordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
    let plan = try coordinator.prepare(
      sourcePath: fixture.source.path, destinationPath: fixture.destination.path,
      graphRevision: 0)
    try FileManager.default.moveItem(
      at: fixture.source, to: fixture.root.appendingPathComponent("original"))
    try FileManager.default.createDirectory(at: fixture.source, withIntermediateDirectories: true)

    #expect(throws: ProjectRelocationError.sourceIdentityChanged) {
      _ = try coordinator.relocate(
        ProjectRelocationRequest(
          operationID: UUID(), sourcePath: fixture.source.path,
          destinationPath: fixture.destination.path,
          expectedSourceIdentity: plan.sourceIdentity, expectedGraphRevision: 0),
        graph: LoopGraph(project: ProjectRef(path: fixture.source.path, name: "source")),
        persistence: ProjectPersistence(baseDirectory: fixture.support))
    }
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test
  func nestedAndCollidingDestinationsAreRejected() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let coordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))

    #expect(throws: ProjectRelocationError.unsafePath) {
      _ = try coordinator.prepare(
        sourcePath: fixture.source.path,
        destinationPath: fixture.source.appendingPathComponent("nested").path,
        graphRevision: 0)
    }
    try FileManager.default.createDirectory(
      at: fixture.root.appendingPathComponent("DESTINATION"),
      withIntermediateDirectories: true)
    #expect(throws: ProjectRelocationError.destinationCollision) {
      _ = try coordinator.prepare(
        sourcePath: fixture.source.path, destinationPath: fixture.destination.path,
        graphRevision: 0)
    }
  }

  @Test
  func symbolicSourceAliasIsRejected() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let alias = fixture.root.appendingPathComponent("alias", isDirectory: true)
    do {
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
    } catch {
      return
    }
    let coordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
    #expect(throws: ProjectRelocationError.unsafePath) {
      _ = try coordinator.prepare(
        sourcePath: alias.path, destinationPath: fixture.destination.path, graphRevision: 0)
    }
  }

  @Test
  func linkedWorktreeAndSubmoduleTopologyIsRejectedBeforeMutation() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("gitdir: C:/synthetic/common/worktrees/source\n".utf8).write(
      to: fixture.source.appendingPathComponent(".git"))
    let coordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
    #expect(throws: ProjectRelocationError.activeWorktrees) {
      _ = try coordinator.prepare(
        sourcePath: fixture.source.path, destinationPath: fixture.destination.path,
        graphRevision: 0)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test
  func postCommitFailureRollsBackWhenTheVerifiedRenameCanBeReversed() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let coordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
      fault: { point in
        if point == .afterFilesystemCommit { throw SyntheticFault() }
      })
    let plan = try coordinator.prepare(
      sourcePath: fixture.source.path, destinationPath: fixture.destination.path,
      graphRevision: 0)
    #expect(throws: ProjectRelocationError.rolledBack) {
      _ = try coordinator.relocate(
        ProjectRelocationRequest(
          operationID: UUID(), sourcePath: fixture.source.path,
          destinationPath: fixture.destination.path,
          expectedSourceIdentity: plan.sourceIdentity, expectedGraphRevision: 0),
        graph: LoopGraph(project: ProjectRef(path: fixture.source.path, name: "source")),
        persistence: ProjectPersistence(baseDirectory: fixture.support))
    }

    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test
  func supportCommitFailureKeepsDestinationAuthoritativeForRecovery() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let persistence = ProjectPersistence(baseDirectory: fixture.support)
    let graph = LoopGraph(project: ProjectRef(path: fixture.source.path, name: "source"))
    persistence.saveGraph(graph)
    let operationID = UUID()
    let coordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
      fault: { point in
        if point == .afterSupportCommit { throw SyntheticFault() }
      })
    let plan = try coordinator.prepare(
      sourcePath: fixture.source.path, destinationPath: fixture.destination.path,
      graphRevision: 0)
    let result = try coordinator.relocate(
      ProjectRelocationRequest(
        operationID: operationID, sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        expectedSourceIdentity: plan.sourceIdentity, expectedGraphRevision: 0),
      graph: graph,
      persistence: persistence)

    #expect(result.recoveryRequired)
    #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(FileManager.default.fileExists(atPath: fixture.destination.path))

    let recovery = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
    let recovered = try recovery.recoverPending(persistence: persistence)
    #expect(recovered.map(\.operationID) == [operationID])
    let replay = try recovery.relocate(
      ProjectRelocationRequest(
        operationID: operationID, sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        expectedSourceIdentity: plan.sourceIdentity, expectedGraphRevision: 0),
      graph: graph,
      persistence: persistence)
    #expect(!replay.recoveryRequired)
  }

  @Test
  func relocationCannotSkipAuthoritativeSupportState() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let coordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))

    #expect(throws: ProjectRelocationError.unsupported) {
      _ = try coordinator.prepare(
        sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        graphRevision: 0,
        options: ProjectRelocationOptions(migrateSupportState: false))
    }
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test
  func failureBeforeCommitLeavesSourceAndSupportStateUntouched() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let persistence = ProjectPersistence(baseDirectory: fixture.support)
    let graph = LoopGraph(project: ProjectRef(path: fixture.source.path, name: "source"))
    persistence.saveGraph(graph)
    let coordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
      fault: { point in
        if point == .beforeFilesystemCommit { throw SyntheticFault() }
      })
    let plan = try coordinator.prepare(
      sourcePath: fixture.source.path, destinationPath: fixture.destination.path,
      graphRevision: 0)
    #expect(throws: ProjectRelocationError.preflightFailed) {
      _ = try coordinator.relocate(
        ProjectRelocationRequest(
          operationID: UUID(), sourcePath: fixture.source.path,
          destinationPath: fixture.destination.path,
          expectedSourceIdentity: plan.sourceIdentity, expectedGraphRevision: 0),
        graph: graph, persistence: persistence)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(persistence.loadGraph(path: fixture.source.path)?.project.path == fixture.source.path)
  }

  @Test
  func crashJournalRecoveryAndDuplicateReplayConvergeOnDestination() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let persistence = ProjectPersistence(baseDirectory: fixture.support)
    let graph = LoopGraph(project: ProjectRef(path: fixture.source.path, name: "source"))
    persistence.saveGraph(graph)
    let operationID = UUID()
    let faulting = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
      fault: { point in
        if point == .afterFilesystemCommit || point == .beforeRollback {
          throw SyntheticFault()
        }
      })
    let plan = try faulting.prepare(
      sourcePath: fixture.source.path, destinationPath: fixture.destination.path,
      graphRevision: 3)
    let request = ProjectRelocationRequest(
      operationID: operationID, sourcePath: fixture.source.path,
      destinationPath: fixture.destination.path,
      expectedSourceIdentity: plan.sourceIdentity, expectedGraphRevision: 3)
    let pending = try faulting.relocate(request, graph: graph, persistence: persistence)
    #expect(pending.recoveryRequired)
    #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(FileManager.default.fileExists(atPath: fixture.destination.path))

    let recoveredCoordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
    let recovered = try recoveredCoordinator.recoverPending(persistence: persistence)
    #expect(recovered.map(\.operationID) == [operationID])
    #expect(
      persistence.loadGraph(path: fixture.destination.path)?.project.path
        == fixture.destination.path)
    #expect(
      try recoveredCoordinator.relocate(
        request, graph: graph, persistence: persistence) == recovered.first)
  }

  @Test
  func protocolV2AdvertisesAndRoundTripsRelocationWhileV1StillDecodes() throws {
    let hello = DaemonWireEnvelope.helloResponse(selectedVersion: 2)
    #expect(hello.capabilities?.contains(ServerCapability.projectRelocation.rawValue) == true)
    let request = ProjectRelocationRequest(
      operationID: UUID(), sourcePath: "C:\\work\\old", destinationPath: "C:\\work\\new",
      expectedSourceIdentity: "identity", expectedGraphRevision: 2)
    let frame = try JSONEncoder().encode(
      DaemonWireEnvelope.request(id: UUID(), command: .relocateProject(request)))
    guard case .v2(let decoded) = try DaemonWireProtocol.decodeClientFrame(frame) else {
      Issue.record("expected v2 request")
      return
    }
    #expect(decoded.command == .relocateProject(request))

    let legacy = try JSONEncoder().encode(DaemonCommand.listRecentProjects)
    #expect(try DaemonWireProtocol.decodeClientFrame(legacy) == .v1(.listRecentProjects))
  }

  @Test
  func registryRejectsRemoteClassificationAndActiveSessionsBeforeMutation() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let paths = WindowsPlatformPaths(homeDirectory: fixture.root)
    let connection = RelocationTestConnection()
    let channel = DaemonConnectionChannel(connection: connection, mode: .v2(version: 2))
    let remoteRegistry = ProjectRegistry(
      persistenceDirectory: fixture.support,
      platformPaths: paths,
      ensureSession: nil,
      terminateSession: nil,
      nodeSessionExists: { _, _ in false },
      classifyProject: { _ in .ssh })
    await remoteRegistry.addConnection(id: connection.id, channel: channel)
    _ = await remoteRegistry.apply(
      .announce(capabilities: [ClientCapability.projectRelocation.rawValue]),
      connectionID: connection.id)
    _ = await remoteRegistry.apply(
      .openProject(path: fixture.source.path), connectionID: connection.id)
    let remoteResult = await remoteRegistry.apply(
      .prepareProjectRelocation(
        sourcePath: fixture.source.path, destinationPath: fixture.destination.path,
        options: ProjectRelocationOptions()),
      connectionID: connection.id)
    #expect(remoteResult?.errorCode == .projectRelocationUnsupported)
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))

    let activeRoot = fixture.root.appendingPathComponent("active", isDirectory: true)
    let activeSource = activeRoot.appendingPathComponent("source", isDirectory: true)
    let activeDestination = activeRoot.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: activeSource, withIntermediateDirectories: true)
    let activeSupport = activeRoot.appendingPathComponent("support", isDirectory: true)
    let activeConnection = RelocationTestConnection()
    let activeRegistry = ProjectRegistry(
      persistenceDirectory: activeSupport,
      platformPaths: paths,
      ensureSession: nil,
      terminateSession: nil,
      nodeSessionExists: { _, _ in true })
    await activeRegistry.addConnection(
      id: activeConnection.id,
      channel: DaemonConnectionChannel(
        connection: activeConnection, mode: .v2(version: 2)))
    _ = await activeRegistry.apply(
      .announce(capabilities: [ClientCapability.projectRelocation.rawValue]),
      connectionID: activeConnection.id)
    _ = await activeRegistry.apply(
      .openProject(path: activeSource.path), connectionID: activeConnection.id)
    _ = await activeRegistry.apply(
      .graphCommand(
        projectPath: activeSource.path,
        command: .createNode(
          NodeDraft(title: "Loop", loopType: .turnBased, firstInstruction: "Work"))),
      connectionID: activeConnection.id)
    let activeResult = await activeRegistry.apply(
      .prepareProjectRelocation(
        sourcePath: activeSource.path, destinationPath: activeDestination.path,
        options: ProjectRelocationOptions()),
      connectionID: activeConnection.id)
    #expect(activeResult?.errorCode == .projectRelocationActiveSessions)
    #expect(FileManager.default.fileExists(atPath: activeSource.path))
    #expect(!FileManager.default.fileExists(atPath: activeDestination.path))
  }

  @Test
  func connectedClientsConvergeOnOneDestinationAndStoreLeaseRejectsMutation() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let paths = WindowsPlatformPaths(homeDirectory: fixture.root)
    let registry = ProjectRegistry(
      persistenceDirectory: fixture.support,
      platformPaths: paths,
      ensureSession: nil,
      terminateSession: nil,
      nodeSessionExists: { _, _ in false })
    let first = RelocationTestConnection()
    let second = RelocationTestConnection()
    for connection in [first, second] {
      await registry.addConnection(
        id: connection.id,
        channel: DaemonConnectionChannel(connection: connection, mode: .v2(version: 2)))
      _ = await registry.apply(
        .announce(capabilities: [ClientCapability.projectRelocation.rawValue]),
        connectionID: connection.id)
      _ = await registry.apply(
        .openProject(path: fixture.source.path), connectionID: connection.id)
    }

    let prepared = await registry.apply(
      .prepareProjectRelocation(
        sourcePath: fixture.source.path, destinationPath: fixture.destination.path,
        options: ProjectRelocationOptions()),
      connectionID: first.id)
    guard case .projectRelocationPrepared(let plan) = prepared?.response else {
      Issue.record("expected relocation plan")
      return
    }
    let operationID = UUID()
    let relocated = await registry.apply(
      .relocateProject(
        ProjectRelocationRequest(
          operationID: operationID,
          sourcePath: fixture.source.path,
          destinationPath: fixture.destination.path,
          expectedSourceIdentity: plan.sourceIdentity,
          expectedGraphRevision: plan.graphRevision)),
      connectionID: first.id)
    guard case .projectRelocated(let result) = relocated?.response else {
      Issue.record("expected relocation result")
      return
    }
    #expect(result.destinationPath == fixture.destination.path)
    #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(FileManager.default.fileExists(atPath: fixture.destination.path))

    for connection in [first, second] {
      let events = connection.frames().compactMap {
        try? JSONDecoder().decode(DaemonWireEnvelope.self, from: $0).event
      }
      #expect(events.contains(.projectRelocated(result)))
      #expect(
        events.contains {
          guard case .graphChanged(let graph) = $0 else { return false }
          return graph.project.path == fixture.destination.path
        })
    }

    let store = GraphStore(
      graph: LoopGraph(project: ProjectRef(path: fixture.destination.path, name: "destination")))
    #expect(await store.beginRelocation(expectedRevision: 0) != nil)
    let mutation = await store.handle(
      .createNode(NodeDraft(title: "Blocked", loopType: .turnBased, firstInstruction: "Work")))
    guard case .rejected(let message, _) = mutation else {
      Issue.record("expected mutation rejection while relocation lease is held")
      return
    }
    #expect(message.contains("relocation"))
    await store.endRelocation()
  }

  private struct SyntheticFault: Error {}
}
