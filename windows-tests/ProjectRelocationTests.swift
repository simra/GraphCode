import Foundation
import GraphcodeKit
import MailroomKit
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

  private func generationDirectory(
    support: URL, projectPath: String, home: URL
  ) -> URL {
    let key = WindowsPlatformPaths(homeDirectory: home).persistenceKey(
      forProjectPath: projectPath)
    return support.appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(".generations", isDirectory: true)
      .appendingPathComponent(key, isDirectory: true)
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
      !FileManager.default.fileExists(
        atPath: generationDirectory(
          support: fixture.support, projectPath: fixture.source.path, home: fixture.root
        ).path))
    #expect(
      FileManager.default.fileExists(
        atPath: generationDirectory(
          support: fixture.support, projectPath: fixture.destination.path, home: fixture.root
        ).path))
    #expect(
      NodeMemory.entries(
        forProjectPath: fixture.destination.path, nodeID: node.id, baseURL: fixture.support
      ).contains(where: { $0.contains("remember") }))
  }

  @Test
  func relocationGenerationCleanupRecoversBeforeAndAfterRemoval() throws {
    for faultPoint in [
      ProjectRelocationFaultPoint.beforeGenerationCleanup,
      .afterGenerationCleanup,
    ] {
      let fixture = try fixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let persistence = ProjectPersistence(
        baseDirectory: fixture.support,
        platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
      let graph = LoopGraph(
        project: ProjectRef(path: fixture.source.path, name: "source", metadata: .local),
        nodes: [LoopNode(id: UUID(), title: "Loop", loopType: .turnBased)])
      try persistence.saveGraphAcknowledged(graph)
      let sourceGenerations = generationDirectory(
        support: fixture.support, projectPath: fixture.source.path, home: fixture.root)
      #expect(FileManager.default.fileExists(atPath: sourceGenerations.path))
      let coordinator = ProjectRelocationCoordinator(
        supportDirectory: fixture.support,
        platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
        fault: { point in
          if point == faultPoint { throw SyntheticFault() }
        })
      let operationID = UUID()
      let plan = try coordinator.prepare(
        operationID: operationID,
        sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        graphRevision: 0,
        persistence: persistence)
      let result = try coordinator.relocate(
        ProjectRelocationRequest(
          operationID: operationID,
          sourcePath: plan.sourcePath,
          destinationPath: plan.destinationPath,
          expectedSourceIdentity: plan.sourceIdentity,
          expectedGraphRevision: plan.graphRevision),
        graph: graph,
        persistence: persistence)
      #expect(result.recoveryRequired)
      #expect(persistence.loadGraph(path: fixture.destination.path) != nil)
      #expect(
        FileManager.default.fileExists(atPath: sourceGenerations.path)
          == (faultPoint == .beforeGenerationCleanup))

      let recovery = ProjectRelocationCoordinator(
        supportDirectory: fixture.support,
        platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
      let statuses = recovery.recoverPending(persistence: persistence)
      #expect(statuses.count == 1)
      #expect(statuses.first?.disposition == .recovered)
      #expect(!FileManager.default.fileExists(atPath: sourceGenerations.path))
      #expect(persistence.loadGraph(path: fixture.source.path) == nil)
      #expect(persistence.loadGraph(path: fixture.destination.path) != nil)
      #expect(recovery.recoverPending(persistence: persistence).isEmpty)
    }
  }

  @Test
  func relocationRejectsPersistenceKeyAliasesAndBoundsRepeatedGenerationCleanup() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let paths = WindowsPlatformPaths(homeDirectory: fixture.root)
    let persistence = ProjectPersistence(baseDirectory: fixture.support, platformPaths: paths)
    #expect(throws: ProjectRelocationError.destinationCollision) {
      try persistence.validateProjectRelocationPersistenceKeys(
        from: fixture.source.path,
        to: fixture.source.path.uppercased())
    }

    var currentPath = fixture.source.path
    var currentGraph = LoopGraph(
      project: ProjectRef(path: currentPath, name: "source", metadata: .local),
      nodes: [LoopNode(id: UUID(), title: "Loop", loopType: .turnBased)])
    try persistence.saveGraphAcknowledged(currentGraph)
    let coordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support, platformPaths: paths)
    for index in 1...4 {
      let destination = fixture.root.appendingPathComponent("destination-\(index)").path
      let plan = try coordinator.prepare(
        sourcePath: currentPath,
        destinationPath: destination,
        graphRevision: index,
        persistence: persistence)
      let result = try coordinator.relocate(
        ProjectRelocationRequest(
          operationID: plan.operationID,
          sourcePath: plan.sourcePath,
          destinationPath: plan.destinationPath,
          expectedSourceIdentity: plan.sourceIdentity,
          expectedGraphRevision: plan.graphRevision),
        graph: currentGraph,
        persistence: persistence)
      #expect(!result.recoveryRequired)
      #expect(
        !FileManager.default.fileExists(
          atPath: generationDirectory(
            support: fixture.support, projectPath: currentPath, home: fixture.root
          ).path))
      currentPath = destination
      currentGraph = try #require(persistence.loadGraph(path: currentPath))
    }
    let generationRoot = fixture.support.appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(".generations", isDirectory: true)
    let remaining = try FileManager.default.contentsOfDirectory(
      at: generationRoot, includingPropertiesForKeys: nil)
    #expect(remaining.count == 1)
    #expect(
      remaining.first?.lastPathComponent
        == paths.persistenceKey(forProjectPath: currentPath))
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
    let recovered = recovery.recoverPending(persistence: persistence)
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
    let recovered = recoveredCoordinator.recoverPending(persistence: persistence)
    #expect(recovered.map(\.operationID) == [operationID])
    #expect(
      persistence.loadGraph(path: fixture.destination.path)?.project.path
        == fixture.destination.path)
    #expect(
      try recoveredCoordinator.relocate(
        request, graph: graph, persistence: persistence
      ).operationID == operationID)
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
        operationID: UUID(),
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
        operationID: UUID(),
        sourcePath: activeSource.path, destinationPath: activeDestination.path,
        options: ProjectRelocationOptions()),
      connectionID: activeConnection.id)
    #expect(activeResult?.errorCode == .projectRelocationActiveSessions)
    #expect(FileManager.default.fileExists(atPath: activeSource.path))
    #expect(!FileManager.default.fileExists(atPath: activeDestination.path))
    let mutationAfterFailure = await activeRegistry.apply(
      .graphCommand(
        projectPath: activeSource.path,
        command: .createNode(
          NodeDraft(title: "Lease released", loopType: .turnBased, firstInstruction: "Work"))),
      connectionID: activeConnection.id)
    #expect(mutationAfterFailure?.error == nil)
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

    let operationID = UUID()
    let prepared = await registry.apply(
      .prepareProjectRelocation(
        operationID: operationID,
        sourcePath: fixture.source.path, destinationPath: fixture.destination.path,
        options: ProjectRelocationOptions()),
      connectionID: first.id)
    guard case .projectRelocationPrepared(let plan) = prepared?.response else {
      Issue.record("expected relocation plan")
      return
    }
    let relocated = await registry.apply(
      .relocateProject(
        ProjectRelocationRequest(
          operationID: operationID,
          sourcePath: plan.sourcePath,
          destinationPath: plan.destinationPath,
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

  @Test
  func prepareRequiresJoinAndOnlyOriginatingClientCanCommitOrReplay() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let registry = ProjectRegistry(
      persistenceDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
      ensureSession: nil,
      terminateSession: nil,
      nodeSessionExists: { _, _ in false })
    let owner = RelocationTestConnection()
    let peer = RelocationTestConnection()
    let unjoined = RelocationTestConnection()
    for connection in [owner, peer, unjoined] {
      await registry.addConnection(
        id: connection.id,
        channel: DaemonConnectionChannel(connection: connection, mode: .v2(version: 2)))
      _ = await registry.apply(
        .announce(capabilities: [ClientCapability.projectRelocation.rawValue]),
        connectionID: connection.id)
    }
    for connection in [owner, peer] {
      _ = await registry.apply(
        .openProject(path: fixture.source.path), connectionID: connection.id)
    }

    let operationID = UUID()
    let deniedPrepare = await registry.apply(
      .prepareProjectRelocation(
        operationID: UUID(),
        sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        options: ProjectRelocationOptions()),
      connectionID: unjoined.id)
    #expect(deniedPrepare?.errorCode == .projectRelocationUnauthorized)

    let prepared = await registry.apply(
      .prepareProjectRelocation(
        operationID: operationID,
        sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        options: ProjectRelocationOptions()),
      connectionID: owner.id)
    guard case .projectRelocationPrepared(let plan) = prepared?.response else {
      Issue.record("expected owner relocation plan")
      return
    }
    let request = ProjectRelocationRequest(
      operationID: operationID,
      sourcePath: plan.sourcePath,
      destinationPath: plan.destinationPath,
      expectedSourceIdentity: plan.sourceIdentity,
      expectedGraphRevision: plan.graphRevision)
    let stolen = await registry.apply(.relocateProject(request), connectionID: peer.id)
    #expect(stolen?.errorCode == .projectRelocationUnauthorized)
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))

    let committed = await registry.apply(.relocateProject(request), connectionID: owner.id)
    guard case .projectRelocated(let result) = committed?.response else {
      Issue.record("expected owner relocation result")
      return
    }
    let replay = await registry.apply(.relocateProject(request), connectionID: owner.id)
    #expect(replay?.response == .projectRelocated(result))
    let guessedReplay = await registry.apply(.relocateProject(request), connectionID: peer.id)
    #expect(guessedReplay?.errorCode == .projectRelocationUnauthorized)
    var changed = request
    changed.destinationPath += "-other"
    let mismatch = await registry.apply(.relocateProject(changed), connectionID: owner.id)
    #expect(mismatch?.errorCode == .projectRelocationConflict)

    let reconnect = RelocationTestConnection()
    await registry.addConnection(
      id: reconnect.id,
      channel: DaemonConnectionChannel(
        connection: reconnect,
        mode: .v2(version: 2),
        clientID: owner.id))
    _ = await registry.apply(
      .announce(capabilities: [ClientCapability.projectRelocation.rawValue]),
      connectionID: reconnect.id)
    let reconnectReplay = await registry.apply(
      .relocateProject(request), connectionID: reconnect.id)
    #expect(reconnectReplay?.response == .projectRelocated(result))
  }

  @Test
  func postCommitProjectErrorRemainsSuccessShapedWhenRollbackIsUnproven() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let persistence = ProjectPersistence(
      baseDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
    let graph = LoopGraph(
      project: ProjectRef(path: fixture.source.path, name: "source"))
    persistence.saveGraph(graph)
    let coordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
      fault: { point in
        if point == .afterFilesystemCommit {
          throw SyntheticFault()
        }
        if point == .beforeRollback {
          throw ProjectRelocationError.permissionDenied
        }
      })
    let operationID = UUID()
    let plan = try coordinator.prepare(
      operationID: operationID,
      sourcePath: fixture.source.path,
      destinationPath: fixture.destination.path,
      graphRevision: 0,
      persistence: persistence)

    let result = try coordinator.relocate(
      ProjectRelocationRequest(
        operationID: operationID,
        sourcePath: plan.sourcePath,
        destinationPath: plan.destinationPath,
        expectedSourceIdentity: plan.sourceIdentity,
        expectedGraphRevision: plan.graphRevision),
      graph: graph,
      persistence: persistence)

    #expect(result.recoveryRequired)
    #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test
  func preparedFieldsAreImmutableAndDisconnectReleasesTheLease() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let registry = ProjectRegistry(
      persistenceDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
      ensureSession: nil,
      terminateSession: nil,
      nodeSessionExists: { _, _ in false })

    func join(_ connection: RelocationTestConnection) async {
      await registry.addConnection(
        id: connection.id,
        channel: DaemonConnectionChannel(connection: connection, mode: .v2(version: 2)))
      _ = await registry.apply(
        .announce(capabilities: [ClientCapability.projectRelocation.rawValue]),
        connectionID: connection.id)
      _ = await registry.apply(
        .openProject(path: fixture.source.path), connectionID: connection.id)
    }

    let first = RelocationTestConnection()
    await join(first)
    let firstOperation = UUID()
    let prepared = await registry.apply(
      .prepareProjectRelocation(
        operationID: firstOperation,
        sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        options: ProjectRelocationOptions()),
      connectionID: first.id)
    guard case .projectRelocationPrepared(let plan) = prepared?.response else {
      Issue.record("expected relocation plan")
      return
    }
    let mismatched = ProjectRelocationRequest(
      operationID: firstOperation,
      sourcePath: plan.sourcePath,
      destinationPath: plan.destinationPath,
      expectedSourceIdentity: plan.sourceIdentity,
      expectedGraphRevision: plan.graphRevision + 1)
    let conflict = await registry.apply(.relocateProject(mismatched), connectionID: first.id)
    #expect(conflict?.errorCode == .projectRelocationConflict)

    let second = RelocationTestConnection()
    await join(second)
    let secondPrepare = await registry.apply(
      .prepareProjectRelocation(
        operationID: UUID(),
        sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        options: ProjectRelocationOptions()),
      connectionID: second.id)
    #expect(secondPrepare?.error == nil)
    await registry.removeConnection(second.id)

    let third = RelocationTestConnection()
    await join(third)
    let thirdPrepare = await registry.apply(
      .prepareProjectRelocation(
        operationID: UUID(),
        sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        options: ProjectRelocationOptions()),
      connectionID: third.id)
    #expect(thirdPrepare?.error == nil)
  }

  @Test
  func worktreeTopologyIntroducedAfterPrepareAbortsBeforeRename() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let registry = ProjectRegistry(
      persistenceDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
      ensureSession: nil,
      terminateSession: nil,
      nodeSessionExists: { _, _ in false })
    let connection = RelocationTestConnection()
    await registry.addConnection(
      id: connection.id,
      channel: DaemonConnectionChannel(connection: connection, mode: .v2(version: 2)))
    _ = await registry.apply(
      .announce(capabilities: [ClientCapability.projectRelocation.rawValue]),
      connectionID: connection.id)
    _ = await registry.apply(
      .openProject(path: fixture.source.path), connectionID: connection.id)
    let operationID = UUID()
    let prepared = await registry.apply(
      .prepareProjectRelocation(
        operationID: operationID,
        sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        options: ProjectRelocationOptions()),
      connectionID: connection.id)
    guard case .projectRelocationPrepared(let plan) = prepared?.response else {
      Issue.record("expected relocation plan")
      return
    }
    try Data("[submodule \"synthetic\"]\n".utf8).write(
      to: fixture.source.appendingPathComponent(".gitmodules"))

    let result = await registry.apply(
      .relocateProject(
        ProjectRelocationRequest(
          operationID: operationID,
          sourcePath: plan.sourcePath,
          destinationPath: plan.destinationPath,
          expectedSourceIdentity: plan.sourceIdentity,
          expectedGraphRevision: plan.graphRevision)),
      connectionID: connection.id)

    #expect(result?.errorCode == .projectRelocationActiveWorktrees)
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test
  func prepareWaitsForSuspendedAttendedLaunchAndRefusesTheNewSession() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let gate = SuspendedSessionLaunch()
    let registry = ProjectRegistry(
      persistenceDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
      ensureSession: nil,
      terminateSession: nil,
      startNodeSession: { _, _ in
        gate.entered.signal()
        gate.release.wait()
        gate.markLive()
        return .success(.started)
      },
      nodeSessionExists: { _, _ in gate.isLive })
    let connection = RelocationTestConnection()
    await joinRelocationConnection(
      connection, registry: registry, projectPath: fixture.source.path)
    let created = await registry.apply(
      .graphCommand(
        projectPath: fixture.source.path,
        command: .createNode(
          NodeDraft(title: "Attended", loopType: .turnBased, firstInstruction: "Work"))),
      connectionID: connection.id)
    guard case .graphChanged(let graph) = created?.response, let nodeID = graph.nodes.first?.id
    else {
      Issue.record("expected attended test loop")
      return
    }

    let launch = Task {
      await registry.apply(
        .openNodeSession(projectPath: fixture.source.path, nodeID: nodeID),
        connectionID: connection.id)
    }
    #expect(gate.entered.wait(timeout: .now() + 2) == .success)
    let completion = CompletionFlag()
    let prepare = Task {
      let result = await registry.apply(
        .prepareProjectRelocation(
          operationID: UUID(),
          sourcePath: fixture.source.path,
          destinationPath: fixture.destination.path,
          options: ProjectRelocationOptions()),
        connectionID: connection.id)
      completion.mark()
      return result
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!completion.value)
    gate.release.signal()

    _ = await launch.value
    let result = await prepare.value
    #expect(result?.errorCode == .projectRelocationActiveSessions)
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test
  func prepareWaitsForSuspendedUnattendedEnsureAndNeverCommitsPastIt() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let gate = SuspendedSessionLaunch()
    let registry = ProjectRegistry(
      persistenceDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
      ensureSession: { _, _ in
        gate.entered.signal()
        gate.release.wait()
        gate.markLive()
      },
      terminateSession: nil,
      nodeSessionExists: { _, _ in gate.isLive })
    let connection = RelocationTestConnection()
    await joinRelocationConnection(
      connection, registry: registry, projectPath: fixture.source.path)
    let create = Task {
      await registry.apply(
        .graphCommand(
          projectPath: fixture.source.path,
          command: .createNode(
            NodeDraft(
              title: "Unattended",
              loopType: .timeBased,
              triggerPrompt: "/loop 1h Work"))),
        connectionID: connection.id)
    }
    #expect(gate.entered.wait(timeout: .now() + 2) == .success)

    let completion = CompletionFlag()
    let prepare = Task {
      let result = await registry.apply(
        .prepareProjectRelocation(
          operationID: UUID(),
          sourcePath: fixture.source.path,
          destinationPath: fixture.destination.path,
          options: ProjectRelocationOptions()),
        connectionID: connection.id)
      completion.mark()
      return result
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!completion.value)
    gate.release.signal()

    let created = await create.value
    #expect(created?.error == nil)
    let result = await prepare.value
    #expect(result?.errorCode == .projectRelocationActiveSessions)
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test
  func disconnectDuringCommitRechecksRetainsLeaseUntilTerminalResult() async throws {
    for suspendedCall in [2, 3] {
      let fixture = try fixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let probe = SuspendedSessionProbe(suspendedCall: suspendedCall)
      let registry = ProjectRegistry(
        persistenceDirectory: fixture.support,
        platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
        ensureSession: nil,
        terminateSession: nil,
        nodeSessionExists: { _, _ in await probe.check() })
      let connection = RelocationTestConnection()
      await joinRelocationConnection(
        connection, registry: registry, projectPath: fixture.source.path)
      let created = await registry.apply(
        .graphCommand(
          projectPath: fixture.source.path,
          command: .createNode(
            NodeDraft(title: "Loop", loopType: .turnBased, firstInstruction: "Work"))),
        connectionID: connection.id)
      #expect(created?.error == nil)
      let operationID = UUID()
      let prepared = await registry.apply(
        .prepareProjectRelocation(
          operationID: operationID,
          sourcePath: fixture.source.path,
          destinationPath: fixture.destination.path,
          options: ProjectRelocationOptions()),
        connectionID: connection.id)
      guard case .projectRelocationPrepared(let plan) = prepared?.response else {
        Issue.record("expected relocation plan")
        return
      }
      let commit = Task {
        await registry.apply(
          .relocateProject(
            ProjectRelocationRequest(
              operationID: operationID,
              sourcePath: plan.sourcePath,
              destinationPath: plan.destinationPath,
              expectedSourceIdentity: plan.sourceIdentity,
              expectedGraphRevision: plan.graphRevision)),
          connectionID: connection.id)
      }
      #expect(probe.entered.wait(timeout: .now() + 2) == .success)
      if suspendedCall == 2 {
        let duplicate = await registry.apply(
          .relocateProject(
            ProjectRelocationRequest(
              operationID: operationID,
              sourcePath: plan.sourcePath,
              destinationPath: plan.destinationPath,
              expectedSourceIdentity: plan.sourceIdentity,
              expectedGraphRevision: plan.graphRevision)),
          connectionID: connection.id)
        #expect(duplicate?.errorCode == .projectRelocationUnauthorized)
      }
      await registry.removeConnection(connection.id)
      probe.release.signal()

      let result = await commit.value
      guard case .projectRelocated = result?.response else {
        Issue.record("expected committed relocation after disconnect")
        return
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
      #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
    }
  }

  @Test
  func duplicateOperationAcrossProjectsDoesNotLeaseTheSecondProject() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let secondSource = fixture.root.appendingPathComponent("second-source", isDirectory: true)
    let secondDestination = fixture.root.appendingPathComponent(
      "second-destination", isDirectory: true)
    try FileManager.default.createDirectory(
      at: secondSource, withIntermediateDirectories: true)
    let registry = ProjectRegistry(
      persistenceDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
      ensureSession: nil,
      terminateSession: nil,
      nodeSessionExists: { _, _ in false })
    let connection = RelocationTestConnection()
    await joinRelocationConnection(
      connection, registry: registry, projectPath: fixture.source.path)
    _ = await registry.apply(
      .openProject(path: secondSource.path), connectionID: connection.id)

    let operationID = UUID()
    let first = await registry.apply(
      .prepareProjectRelocation(
        operationID: operationID,
        sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        options: ProjectRelocationOptions()),
      connectionID: connection.id)
    guard case .projectRelocationPrepared(let plan) = first?.response else {
      Issue.record("expected first project plan")
      return
    }
    let duplicate = await registry.apply(
      .prepareProjectRelocation(
        operationID: operationID,
        sourcePath: secondSource.path,
        destinationPath: secondDestination.path,
        options: ProjectRelocationOptions()),
      connectionID: connection.id)
    #expect(duplicate?.errorCode == .projectRelocationConflict)
    let secondMutation = await registry.apply(
      .graphCommand(
        projectPath: secondSource.path,
        command: .createNode(
          NodeDraft(title: "Still writable", loopType: .turnBased, firstInstruction: "Work"))),
      connectionID: connection.id)
    #expect(secondMutation?.error == nil)

    let committed = await registry.apply(
      .relocateProject(
        ProjectRelocationRequest(
          operationID: operationID,
          sourcePath: plan.sourcePath,
          destinationPath: plan.destinationPath,
          expectedSourceIdentity: plan.sourceIdentity,
          expectedGraphRevision: plan.graphRevision)),
      connectionID: connection.id)
    #expect(committed?.error == nil)
    #expect(FileManager.default.fileExists(atPath: secondSource.path))
    #expect(!FileManager.default.fileExists(atPath: secondDestination.path))
  }

  @Test
  func leaseBlocksSessionStartsAndFinalSessionRecheckAbortsCommit() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    final class SessionSwitch: @unchecked Sendable {
      private let lock = NSLock()
      private var value = false
      func set(_ value: Bool) { lock.withLock { self.value = value } }
      func get() -> Bool { lock.withLock { value } }
    }
    let sessions = SessionSwitch()
    let registry = ProjectRegistry(
      persistenceDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root),
      ensureSession: nil,
      terminateSession: nil,
      nodeSessionExists: { _, _ in sessions.get() })
    let connection = RelocationTestConnection()
    await registry.addConnection(
      id: connection.id,
      channel: DaemonConnectionChannel(connection: connection, mode: .v2(version: 2)))
    _ = await registry.apply(
      .announce(capabilities: [ClientCapability.projectRelocation.rawValue]),
      connectionID: connection.id)
    _ = await registry.apply(
      .openProject(path: fixture.source.path), connectionID: connection.id)
    let created = await registry.apply(
      .graphCommand(
        projectPath: fixture.source.path,
        command: .createNode(
          NodeDraft(title: "Loop", loopType: .turnBased, firstInstruction: "Work"))),
      connectionID: connection.id)
    guard case .graphChanged(let graph) = created?.response, let nodeID = graph.nodes.first?.id
    else {
      Issue.record("expected test loop")
      return
    }
    let operationID = UUID()
    let prepared = await registry.apply(
      .prepareProjectRelocation(
        operationID: operationID,
        sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        options: ProjectRelocationOptions()),
      connectionID: connection.id)
    guard case .projectRelocationPrepared(let plan) = prepared?.response else {
      Issue.record("expected leased relocation")
      return
    }
    let openSession = await registry.apply(
      .openNodeSession(projectPath: fixture.source.path, nodeID: nodeID),
      connectionID: connection.id)
    #expect(openSession?.error?.contains("relocation") == true)
    let deletion = await registry.apply(
      .deleteProjectGraph(path: fixture.source.path), connectionID: connection.id)
    #expect(deletion?.error?.contains("relocation") == true)

    sessions.set(true)
    let commit = await registry.apply(
      .relocateProject(
        ProjectRelocationRequest(
          operationID: operationID,
          sourcePath: plan.sourcePath,
          destinationPath: plan.destinationPath,
          expectedSourceIdentity: plan.sourceIdentity,
          expectedGraphRevision: plan.graphRevision)),
      connectionID: connection.id)
    #expect(commit?.errorCode == .projectRelocationActiveSessions)
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  @Test
  func staleDestinationSupportStateIsNeverOverwritten() throws {
    enum Surface: CaseIterable { case graphAndMailroom, recents, open, memory, history }
    for surface in Surface.allCases {
      let fixture = try fixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let persistence = ProjectPersistence(baseDirectory: fixture.support)
      let sentinelNode = UUID()
      switch surface {
      case .graphAndMailroom:
        var graph = LoopGraph(
          project: ProjectRef(path: fixture.destination.path, name: "stale"))
        graph.mailroom = [
          MailroomPost(
            id: 1, at: Date(timeIntervalSince1970: 1), authorID: nil,
            author: "fixture", topic: nil, body: "do not overwrite")
        ]
        persistence.saveGraph(graph)
      case .recents:
        persistence.recordOpened(ProjectRef(path: fixture.destination.path, name: "stale"))
      case .open:
        persistence.saveOpenProjects([fixture.destination.path])
      case .memory:
        let url = NodeMemory.logURL(
          forProjectPath: fixture.destination.path,
          nodeID: sentinelNode,
          baseURL: fixture.support)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("destination sentinel\n".utf8).write(to: url)
      case .history:
        var history = LoopHistory()
        history.record(.loop(projectPath: fixture.destination.path, nodeID: sentinelNode))
        LoopHistoryStore(baseDirectory: fixture.support).save(history)
      }
      let coordinator = ProjectRelocationCoordinator(
        supportDirectory: fixture.support,
        platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
      #expect(throws: ProjectRelocationError.destinationCollision) {
        _ = try coordinator.prepare(
          sourcePath: fixture.source.path,
          destinationPath: fixture.destination.path,
          graphRevision: 0,
          persistence: persistence)
      }
      #expect(FileManager.default.fileExists(atPath: fixture.source.path))
      #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
      switch surface {
      case .graphAndMailroom:
        #expect(
          persistence.loadGraph(path: fixture.destination.path)?.mailroom.first?.body
            == "do not overwrite")
      case .recents:
        #expect(persistence.loadRecentProjects().contains { $0.path == fixture.destination.path })
      case .open:
        #expect(persistence.loadOpenProjects() == [fixture.destination.path])
      case .memory:
        #expect(
          NodeMemory.entries(
            forProjectPath: fixture.destination.path,
            nodeID: sentinelNode,
            baseURL: fixture.support
          ).contains("destination sentinel"))
      case .history:
        #expect(
          LoopHistoryStore(baseDirectory: fixture.support)
            .containsProjectPath(fixture.destination.path))
      }
    }
  }

  @Test
  func graphWriterDrainPreventsOldPathRecreation() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let persistence = ProjectPersistence(baseDirectory: fixture.support)
    let enteredWrite = DispatchSemaphore(value: 0)
    let releaseWrite = DispatchSemaphore(value: 0)
    let relocationFinished = DispatchSemaphore(value: 0)
    let graph = LoopGraph(project: ProjectRef(path: fixture.source.path, name: "source"))
    let writer = GraphWriter(
      persistence: persistence,
      beforeWrite: { _ in
        enteredWrite.signal()
        releaseWrite.wait()
      })
    writer.save(graph)
    #expect(enteredWrite.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
      writer.beginRelocation(path: fixture.source.path)
      relocationFinished.signal()
    }
    releaseWrite.signal()
    #expect(relocationFinished.wait(timeout: .now() + 2) == .success)
    persistence.deleteGraph(path: fixture.source.path)
    writer.save(graph)
    writer.flush()
    #expect(persistence.loadGraph(path: fixture.source.path) == nil)
  }

  @Test
  func destinationParentReparseAliasIsRejected() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let realParent = fixture.root.appendingPathComponent("real-parent", isDirectory: true)
    let aliasParent = fixture.root.appendingPathComponent("alias-parent", isDirectory: true)
    try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
    do {
      try FileManager.default.createSymbolicLink(
        at: aliasParent, withDestinationURL: realParent)
    } catch {
      return
    }
    let coordinator = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
    #expect(throws: ProjectRelocationError.unsafePath) {
      _ = try coordinator.prepare(
        sourcePath: fixture.source.path,
        destinationPath: aliasParent.appendingPathComponent("destination").path,
        graphRevision: 0)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
  }

  @Test
  func corruptJournalIsQuarantinedWithoutBlockingValidRecovery() throws {
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
        if point == .afterFilesystemCommit || point == .beforeRollback {
          throw SyntheticFault()
        }
      })
    let plan = try coordinator.prepare(
      operationID: operationID,
      sourcePath: fixture.source.path,
      destinationPath: fixture.destination.path,
      graphRevision: 0,
      persistence: persistence)
    let pending = try coordinator.relocate(
      ProjectRelocationRequest(
        operationID: operationID,
        sourcePath: plan.sourcePath,
        destinationPath: plan.destinationPath,
        expectedSourceIdentity: plan.sourceIdentity,
        expectedGraphRevision: plan.graphRevision),
      graph: graph,
      persistence: persistence)
    #expect(pending.recoveryRequired)
    let journals = fixture.support.appendingPathComponent(
      "project-relocations\\journals", isDirectory: true)
    try Data("{broken".utf8).write(
      to: journals.appendingPathComponent("00000000-corrupt.json"))

    let recovery = ProjectRelocationCoordinator(
      supportDirectory: fixture.support,
      platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
    let statuses = recovery.recoverPending(persistence: persistence)
    #expect(statuses.count == 2)
    #expect(statuses.contains { $0.disposition == .quarantined })
    #expect(
      statuses.contains {
        $0.operationID == operationID && $0.disposition == .recovered
      })
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.support.appendingPathComponent(
          "project-relocations\\quarantine\\00000000-corrupt.json"
        ).path))
    #expect(
      persistence.loadGraph(path: fixture.destination.path)?.project.path
        == fixture.destination.path)
  }

  @Test
  func staleReceiptAndJournalDestinationKeysBlockReuse() throws {
    for leaveJournal in [false, true] {
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
          if leaveJournal,
            point == .afterFilesystemCommit || point == .beforeRollback
          {
            throw SyntheticFault()
          }
        })
      let plan = try coordinator.prepare(
        operationID: operationID,
        sourcePath: fixture.source.path,
        destinationPath: fixture.destination.path,
        graphRevision: 0,
        persistence: persistence)
      let result = try coordinator.relocate(
        ProjectRelocationRequest(
          operationID: operationID,
          sourcePath: plan.sourcePath,
          destinationPath: plan.destinationPath,
          expectedSourceIdentity: plan.sourceIdentity,
          expectedGraphRevision: plan.graphRevision),
        graph: graph,
        persistence: persistence)
      #expect(result.recoveryRequired == leaveJournal)
      let archived = fixture.root.appendingPathComponent("moved-aside", isDirectory: true)
      try FileManager.default.moveItem(at: fixture.destination, to: archived)
      persistence.deleteGraph(path: fixture.destination.path)
      persistence.forgetProject(path: fixture.destination.path)
      persistence.saveOpenProjects([])
      try FileManager.default.createDirectory(
        at: fixture.source, withIntermediateDirectories: true)
      let next = ProjectRelocationCoordinator(
        supportDirectory: fixture.support,
        platformPaths: WindowsPlatformPaths(homeDirectory: fixture.root))
      #expect(throws: ProjectRelocationError.destinationCollision) {
        _ = try next.prepare(
          sourcePath: fixture.source.path,
          destinationPath: fixture.destination.path,
          graphRevision: 0,
          persistence: persistence)
      }
      #expect(FileManager.default.fileExists(atPath: archived.path))
      #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    }
  }

  private struct SyntheticFault: Error {}

  private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var value: Bool { lock.withLock { completed } }
    func mark() { lock.withLock { completed = true } }
  }

  private final class SuspendedSessionLaunch: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var live = false
    var isLive: Bool { lock.withLock { live } }
    func markLive() { lock.withLock { live = true } }
  }

  private final class SuspendedSessionProbe: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private let suspendedCall: Int

    init(suspendedCall: Int) {
      self.suspendedCall = suspendedCall
    }

    func check() async -> Bool {
      let shouldSuspend = lock.withLock {
        calls += 1
        return calls == suspendedCall
      }
      if shouldSuspend {
        entered.signal()
        release.wait()
      }
      return false
    }
  }

  private func joinRelocationConnection(
    _ connection: RelocationTestConnection,
    registry: ProjectRegistry,
    projectPath: String
  ) async {
    await registry.addConnection(
      id: connection.id,
      channel: DaemonConnectionChannel(connection: connection, mode: .v2(version: 2)))
    _ = await registry.apply(
      .announce(capabilities: [ClientCapability.projectRelocation.rawValue]),
      connectionID: connection.id)
    _ = await registry.apply(
      .openProject(path: projectPath), connectionID: connection.id)
  }
}
