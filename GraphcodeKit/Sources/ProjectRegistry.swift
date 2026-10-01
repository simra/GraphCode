import Foundation

final class ProjectSessionLaunchBarrier: @unchecked Sendable {
  struct LaunchToken: Sendable {
    let path: String
    let generation: UInt64
    let id: UUID
  }

  private struct State {
    var generation: UInt64 = 0
    var launches: Set<UUID> = []
    var relocationOwner: UUID?
    var waiter: CheckedContinuation<Bool, Never>?
  }

  private let lock = NSLock()
  private var states: [String: State] = [:]

  func beginLaunch(path: String) -> LaunchToken? {
    lock.lock()
    defer { lock.unlock() }
    var state = states[path] ?? State()
    guard state.relocationOwner == nil else { return nil }
    let token = LaunchToken(path: path, generation: state.generation, id: UUID())
    state.launches.insert(token.id)
    states[path] = state
    return token
  }

  func isCurrent(_ token: LaunchToken) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let state = states[token.path] else { return false }
    return state.generation == token.generation
      && state.relocationOwner == nil
      && state.launches.contains(token.id)
  }

  func endLaunch(_ token: LaunchToken) {
    var continuation: CheckedContinuation<Bool, Never>?
    lock.lock()
    if var state = states[token.path] {
      state.launches.remove(token.id)
      if state.launches.isEmpty, state.relocationOwner != nil {
        continuation = state.waiter
        state.waiter = nil
      }
      if state.launches.isEmpty, state.relocationOwner == nil {
        states.removeValue(forKey: token.path)
      } else {
        states[token.path] = state
      }
    }
    lock.unlock()
    continuation?.resume(returning: true)
  }

  func beginRelocation(path: String, owner: UUID) async -> Bool {
    await withCheckedContinuation { continuation in
      lock.lock()
      var state = states[path] ?? State()
      guard state.relocationOwner == nil else {
        lock.unlock()
        continuation.resume(returning: false)
        return
      }
      state.generation &+= 1
      state.relocationOwner = owner
      if state.launches.isEmpty {
        states[path] = state
        lock.unlock()
        continuation.resume(returning: true)
      } else {
        state.waiter = continuation
        states[path] = state
        lock.unlock()
      }
    }
  }

  func endRelocation(path: String, owner: UUID) {
    var continuation: CheckedContinuation<Bool, Never>?
    lock.lock()
    if var state = states[path], state.relocationOwner == owner {
      state.generation &+= 1
      state.relocationOwner = nil
      continuation = state.waiter
      state.waiter = nil
      if state.launches.isEmpty {
        states.removeValue(forKey: path)
      } else {
        states[path] = state
      }
    }
    lock.unlock()
    continuation?.resume(returning: false)
  }
}

public struct ProjectRegistryCommandResult: Equatable, Sendable {
  public let response: DaemonEvent?
  public let error: String?
  public let errorCode: DaemonWireErrorCode?
  /// A successful command may intentionally have no response payload (for example,
  /// `.forgetProject`). The daemon uses this bit to distinguish that outcome from an
  /// internal routing failure.
  public let succeeded: Bool
  public let closeConnectionAfterResponse: Bool
  public let remoteAssetDeliveryID: UUID?

  public init(
    response: DaemonEvent? = nil,
    error: String? = nil,
    errorCode: DaemonWireErrorCode? = nil,
    succeeded: Bool? = nil,
    closeConnectionAfterResponse: Bool = false,
    remoteAssetDeliveryID: UUID? = nil
  ) {
    self.response = response
    self.error = error
    self.errorCode = errorCode
    self.succeeded = succeeded ?? (error == nil)
    self.closeConnectionAfterResponse = closeConnectionAfterResponse
    self.remoteAssetDeliveryID = remoteAssetDeliveryID
  }
}

/// Owns every open project's `GraphStore`, keyed by canonicalized folder path — this is
/// what `graphcoded` instantiates instead of a single bare `GraphStore` from Phase 4 on
/// (see docs/07-roadmap.md#phase-4--projects). Multi-project routing lives entirely
/// here: `GraphStore` itself still only ever handles one graph and has no idea this
/// layer exists.
///
/// One connection (one socket, one `graphcode.app` instance) can have any number of
/// projects open at once — the sidebar shows every folder the app has opened, not just
/// the most recent one (see docs/07-roadmap.md's Projects phase follow-up). `.openProject`
/// *adds* to the connection's joined-project set rather than replacing it;
/// `connectionProjectPaths` tracks that set so a full disconnect can detach from every
/// joined `GraphStore`, not just one.
///
/// The open set is shared, not per-connection: whoever opens a folder — the app, the CLI,
/// an editor plugin driving the CLI — adds it for everyone, so every attached sidebar is
/// joined to it there and then (`joinSidebars`) instead of finding out at its next launch.
///
/// The registry also owns which projects the sidebar should show on next launch, kept in
/// `open-projects.json` separately from the recents index. That separation is what gives
/// the sidebar's context menu three distinct verbs: `.closeProject` drops a project from
/// the open set only, `.forgetProject` also removes it from recents, and
/// `.deleteProjectGraph` additionally discards its saved loops.
public actor ProjectRegistry {
  private struct AttachmentCreateTarget {
    var draft: NodeDraft
    var graphPath: [UUID]
  }

  private struct AttachmentCreateAddressError: Error {
    var message: String
    var draft: NodeDraft
  }

  private let persistence: ProjectPersistence
  /// Writes graphs off the store's actor — see `GraphWriter`. `nonisolated` so the
  /// daemon can flush it from a signal handler without an actor hop.
  private nonisolated let writer: GraphWriter
  /// For tests that read the file straight after a command: every save is flushed
  /// before the store's turn ends, so the disk is exactly what the store holds.
  private let persistsSynchronously: Bool
  private let quickChatStore: QuickChatStore
  private let platformPaths: any PlatformPaths
  private let replayStore: DaemonReplayStore
  private let remoteAssets: RemoteAssetStore
  private let settingsURL: URL
  private let classifyProject: @Sendable (String) -> ProjectMetadata
  private let relocationCoordinator: ProjectRelocationCoordinator
  private let sessionLaunchBarrier = ProjectSessionLaunchBarrier()
  private struct PreparingRelocation {
    var connectionID: UUID
    var sourcePath: String
    var generation: UUID
  }
  private enum RelocationPhase {
    case prepared
    case committing(UUID)
  }
  private struct PreparedRelocation {
    var connectionID: UUID
    var clientID: UUID
    var plan: ProjectRelocationPlan
    var options: ProjectRelocationOptions
    var graph: LoopGraph
    var store: GraphStore
    var generation: UUID
    var phase: RelocationPhase
    var writerBlocked: Bool
  }
  private var preparingRelocations: [UUID: PreparingRelocation] = [:]
  private var preparedRelocations: [UUID: PreparedRelocation] = [:]
  private var stores: [String: GraphStore] = [:]
  private var connections: [UUID: DaemonConnectionChannel] = [:]
  private var connectionClientIDs: [UUID: UUID] = [:]
  private var connectionProjectPaths: [UUID: Set<String>] = [:]
  /// Connections that asked for the whole open set (`.restoreOpenProjects`) rather than
  /// one named project — see `sidebarSubscribers`.
  private var sidebarConnections: Set<UUID> = []
  private let ensureSession: (@Sendable (LoopNode, String?) async -> Void)?
  private let terminateSession: (@Sendable (LoopNode, String?) -> Void)?
  private let restartSession: (@Sendable (LoopNode, String?) async -> Bool)?
  private let startNodeSession:
    (@Sendable (LoopNode, String?) async -> Result<CLISessionStartOutcome, CLISessionError>)?
  private let nodeSessionExists: (@Sendable (LoopNode, String?) async -> Bool)?
  private let findMissingProvider: (@Sendable (LoopNode, String?) async -> LaunchFailure?)?
  private let startQuickChat:
    (@Sendable (LoopNode, String?) async -> Result<CLISessionStartOutcome, CLISessionError>)?
  private let terminateQuickChat:
    (@Sendable (LoopNode, String?) async -> Result<Void, CLISessionError>)?
  private let quickChatExists: (@Sendable (LoopNode, String?) async -> Bool)?
  private let enumerateQuickChatSessions: (@Sendable () async -> [UUID])?
  private let evaluatePredicate: (@Sendable (ShellPredicate) async -> Bool)?
  private let checkPredicate: (@Sendable (ShellPredicate) async -> PredicateOutcome?)?
  private let deliverMessage: (@Sendable (LoopNode, String, String?) async -> Bool)?
  private let captureScript: (@Sendable (ShellPredicate) async -> String?)?
  private let readUsage: (@Sendable (LoopNode, String?) async -> UsageSample?)?
  private let readGoalVerdict: (@Sendable (LoopNode, String?) async -> GoalVerdict?)?
  private let readActivity: (@Sendable (LoopNode, String?) async -> String?)?
  private let readSummary: (@Sendable (LoopNode, String?) async -> SummaryReading?)?
  private let readPresence: (@Sendable (LoopNode, String?) async -> PresenceReading)?
  private let sessionAlive: (@Sendable (LoopNode, String?) async -> Bool)?
  private let composeBoard:
    (@Sendable (LoopNode, LoopSummary, String?, String?) async -> SummaryBoard?)?
  private let readTranscript:
    @Sendable (LoopNode, String?, TranscriptQuery) async -> Result<
      TranscriptPage, TranscriptReadError
    >
  private let readNodeResource:
    @Sendable (LoopNode, String, NodeResourceQuery) -> Result<
      NodeResourcePage, NodeResourceReadError
    >
  /// Non-nil only while at least one client is attached — see `startPresencePolling`.
  private var presencePoller: Task<Void, Never>?
  /// Runs only while the sleep assertion is held — see `refreshAwakeAssertion`.
  private var awakeRecheck: Task<Void, Never>?

  /// Quick Chats are session-backed records too. Reusing the GraphStore launcher
  /// closures keeps their zmx identity stable (the chat UUID is the LoopNode UUID)
  /// without inventing a second session protocol.
  private func quickChatNode(_ chat: QuickChat) -> LoopNode {
    LoopNode(
      id: chat.id,
      title: chat.title,
      loopType: .turnBased,
      backend: chat.backend,
      state: .idle,
      createdAt: chat.createdAt)
  }

  private func ensureQuickChatSession(_ chat: QuickChat) async -> Result<
    CLISessionStartOutcome, CLISessionError
  > {
    guard let startQuickChat else { return .failure(.unavailable("session launcher unavailable")) }
    return await startQuickChat(quickChatNode(chat), nil)
  }

  private func terminateQuickChatSession(_ chat: QuickChat) async -> Result<Void, CLISessionError> {
    guard let terminateQuickChat else {
      return .failure(.unavailable("session launcher unavailable"))
    }
    return await terminateQuickChat(quickChatNode(chat), nil)
  }

  private enum NodeLaunchAuthority {
    case connection(UUID)
    case daemon
  }

  private func preparedLaunchCopy(
    _ node: LoopNode,
    projectPath: String,
    metadata: ProjectMetadata,
    authority: NodeLaunchAuthority
  ) async -> Result<LoopNode, RemoteAssetError> {
    if case .connection(let connectionID) = authority {
      guard connectionProjectPaths[connectionID]?.contains(projectPath) == true else {
        return .failure(.unauthorized)
      }
    }
    var copy = node
    var resolved: [PromptAttachment] = []
    resolved.reserveCapacity(node.attachments.count)
    for attachment in node.attachments {
      switch await remoteAssets.resolvedPath(
        for: attachment, projectPath: projectPath, nodeID: node.id, metadata: metadata)
      {
      case .success(let path):
        resolved.append(
          PromptAttachment(id: attachment.id, path: path, name: attachment.fileName))
      case .failure(let failure):
        return .failure(failure)
      }
    }
    copy.attachments = resolved
    return .success(copy)
  }

  private func ensurePreparedSession(
    _ node: LoopNode,
    projectPath: String?,
    launch: @escaping @Sendable (LoopNode, String?) async -> Void
  ) async {
    guard let projectPath,
      let token = sessionLaunchBarrier.beginLaunch(path: projectPath)
    else { return }
    defer { sessionLaunchBarrier.endLaunch(token) }
    guard sessionLaunchBarrier.isCurrent(token) else { return }
    switch await preparedLaunchCopy(
      node, projectPath: projectPath, metadata: classifyProject(projectPath), authority: .daemon)
    {
    case .success(let copy):
      guard sessionLaunchBarrier.isCurrent(token) else { return }
      await launch(copy, projectPath)
    case .failure(let failure):
      await broadcast(.errorOccurred("loop session unavailable: \(failure.message)"))
    }
  }

  private func restartPreparedSession(
    _ node: LoopNode,
    projectPath: String?,
    restart: @escaping @Sendable (LoopNode, String?) async -> Bool
  ) async -> Bool {
    guard let projectPath,
      let token = sessionLaunchBarrier.beginLaunch(path: projectPath)
    else { return false }
    defer { sessionLaunchBarrier.endLaunch(token) }
    guard sessionLaunchBarrier.isCurrent(token) else { return false }
    switch await preparedLaunchCopy(
      node, projectPath: projectPath, metadata: classifyProject(projectPath), authority: .daemon)
    {
    case .success(let copy):
      guard sessionLaunchBarrier.isCurrent(token) else { return false }
      return await restart(copy, projectPath)
    case .failure(let failure):
      await broadcast(.errorOccurred("loop session unavailable: \(failure.message)"))
      return false
    }
  }

  /// These default to the real `ZmxSessionLauncher`/`ShellPredicateEvaluator` closures —
  /// every `GraphStore` this registry creates gets them, so an unattended node's session
  /// is (re)started as soon as its project's graph is loaded, torn down when the node is
  /// deleted, and a goal's stop condition is polled while it runs. Tests pass their own
  /// closures, or `nil` to touch no real sessions or subprocesses at all.
  public init(
    persistenceDirectory: URL,
    platformPaths: any PlatformPaths = CurrentPlatformPaths.value,
    replayStore: DaemonReplayStore = DaemonReplayStore(),
    remoteAssets: RemoteAssetStore? = nil,
    settingsURL: URL = GraphcodeSettingsStore.url,
    ensureSession: (@Sendable (LoopNode, String?) async -> Void)? = CLISessionBackend.ensureSession,
    terminateSession: (@Sendable (LoopNode, String?) -> Void)? =
      CLISessionBackend.terminateSession,
    restartSession: (@Sendable (LoopNode, String?) async -> Bool)? =
      CLISessionBackend.restartSession,
    startNodeSession: (
      @Sendable (LoopNode, String?) async -> Result<CLISessionStartOutcome, CLISessionError>
    )? = nil,
    nodeSessionExists: (@Sendable (LoopNode, String?) async -> Bool)? = nil,
    findMissingProvider: (@Sendable (LoopNode, String?) async -> LaunchFailure?)? = nil,
    evaluatePredicate: (@Sendable (ShellPredicate) async -> Bool)? = ShellPredicateEvaluator
      .evaluate,
    checkPredicate: (@Sendable (ShellPredicate) async -> PredicateOutcome?)? =
      ShellPredicateEvaluator.check,
    deliverMessage: (@Sendable (LoopNode, String, String?) async -> Bool)? =
      CLISessionBackend.deliverMessage,
    captureScript: (@Sendable (ShellPredicate) async -> String?)? = ShellPredicateEvaluator.capture,
    readUsage: (@Sendable (LoopNode, String?) async -> UsageSample?)? =
      CLISessionBackend.readUsage,
    readGoalVerdict: (@Sendable (LoopNode, String?) async -> GoalVerdict?)? =
      CLISessionBackend.readGoalVerdict,
    readActivity: (@Sendable (LoopNode, String?) async -> String?)? =
      CLISessionBackend.readActivity,
    readSummary: (@Sendable (LoopNode, String?) async -> SummaryReading?)? =
      CLISessionBackend.readSummary,
    readPresence: (@Sendable (LoopNode, String?) async -> PresenceReading)? =
      CLISessionBackend.readPresence,
    sessionAlive: (@Sendable (LoopNode, String?) async -> Bool)? = CLISessionBackend.sessionAlive,
    composeBoard: (@Sendable (LoopNode, LoopSummary, String?, String?) async -> SummaryBoard?)? =
      CLISessionBackend.composeBoard,
    readTranscript:
      @escaping @Sendable (
        LoopNode, String?, TranscriptQuery
      ) async -> Result<TranscriptPage, TranscriptReadError> = { node, path, query in
        await TranscriptReader.read(node: node, projectPath: path, query: query)
      },
    readNodeResource:
      @escaping @Sendable (
        LoopNode, String, NodeResourceQuery
      ) -> Result<NodeResourcePage, NodeResourceReadError> = { node, path, query in
        NodeResourceReader.read(node: node, projectPath: path, query: query)
      },
    reapCondemnedSessions: Bool = false,
    persistsSynchronously: Bool = false,
    startQuickChat: (
      @Sendable (LoopNode, String?) async -> Result<CLISessionStartOutcome, CLISessionError>
    )? = nil,
    terminateQuickChat: (@Sendable (LoopNode, String?) async -> Result<Void, CLISessionError>)? =
      nil,
    quickChatExists: (@Sendable (LoopNode, String?) async -> Bool)? = nil,
    enumerateQuickChatSessions: (@Sendable () async -> [UUID])? = nil,
    relocationCoordinator: ProjectRelocationCoordinator? = nil,
    beforeGraphWrite: @escaping @Sendable (LoopGraph) throws -> Void = { _ in },
    beforeGraphDelete: @escaping @Sendable (String) throws -> Void = { _ in },
    classifyProject: @escaping @Sendable (String) -> ProjectMetadata = {
      ProjectMetadata.inferred(fromProjectPath: $0)
    }
  ) {
    self.platformPaths = platformPaths
    persistence = ProjectPersistence(
      baseDirectory: persistenceDirectory, platformPaths: platformPaths,
      beforeGraphWrite: beforeGraphWrite, beforeGraphDelete: beforeGraphDelete)
    writer = GraphWriter(persistence: persistence)
    self.persistsSynchronously = persistsSynchronously
    quickChatStore = QuickChatStore(baseDirectory: persistenceDirectory)
    self.replayStore = replayStore
    self.remoteAssets =
      remoteAssets
      ?? RemoteAssetStore(
        catalogURL: persistenceDirectory.appendingPathComponent(
          "remote-assets/catalog.json"))
    self.settingsURL = settingsURL
    self.classifyProject = classifyProject
    self.relocationCoordinator =
      relocationCoordinator
      ?? ProjectRelocationCoordinator(
        supportDirectory: persistenceDirectory, platformPaths: platformPaths)
    self.ensureSession = ensureSession
    self.terminateSession = terminateSession
    self.restartSession = restartSession
    self.startNodeSession =
      startNodeSession ?? { node, path in
        await ZmxSessionLauncher.startAttendedResult(node, projectPath: path)
      }
    self.nodeSessionExists =
      nodeSessionExists ?? { node, path in
        await CLISessionBackend.backend(for: node).exists(node, path)
      }
    self.findMissingProvider =
      findMissingProvider ?? { node, path in
        await ProviderPath.missingProvider(for: node, projectPath: path)
      }
    self.evaluatePredicate = evaluatePredicate
    self.checkPredicate = checkPredicate
    self.deliverMessage = deliverMessage
    self.captureScript = captureScript
    self.readUsage = readUsage
    self.readGoalVerdict = readGoalVerdict
    self.readActivity = readActivity
    self.readSummary = readSummary
    self.readPresence = readPresence
    self.sessionAlive = sessionAlive
    self.composeBoard = composeBoard
    self.readTranscript = readTranscript
    self.readNodeResource = readNodeResource
    self.startQuickChat =
      startQuickChat ?? { node, path in
        let result = await CLISessionBackend.backend(for: node).startResult(node, path)
        if case .success = result { QuickChatSessionRegistry.markLive(node.id) }
        return result
      }
    self.terminateQuickChat =
      terminateQuickChat ?? { node, path in
        let result = await CLISessionBackend.backend(for: node).terminateResult(node, path)
        if case .success = result { QuickChatSessionRegistry.remove(node.id) }
        return result
      }
    self.quickChatExists =
      quickChatExists ?? { node, path in
        await CLISessionBackend.backend(for: node).exists(node, path)
      }
    self.enumerateQuickChatSessions =
      enumerateQuickChatSessions ?? {
        await CLISessionBackend.backend(for: .init(title: "", backend: .claudeCode)).enumerate()
      }
    // The reap half of the two-phase kill (`CondemnedSessions`): once at startup, for a
    // delete whose daemon died between condemning a session and confirming it dead, and
    // then on a timer for kills `zmx` failed transiently. This is explicit rather than
    // inferred from injected session closures: tests commonly provide non-nil stubs and
    // must never touch the user's real zmx.
    if reapCondemnedSessions {
      condemnedReaper = Task {
        await ZmxSessionLauncher.reapCondemnedSessions()
        while !Task.isCancelled {
          try? await Task.sleep(for: Self.condemnedReapInterval)
          guard !Task.isCancelled else { return }
          await ZmxSessionLauncher.reapCondemnedSessions()
        }
      }
    }
    let recoveryStatuses = self.relocationCoordinator.recoverPending(persistence: persistence)
    for status in recoveryStatuses {
      DaemonLog.shared.record(
        "project-relocation-recovery",
        [
          ("operation", status.operationID?.uuidString ?? "unknown"),
          ("disposition", status.disposition.rawValue),
          ("detail", status.detail),
        ])
    }
    Task { [weak self] in
      await self?.recoverRemoteAssetsAtStartup()
    }
  }

  /// Waits for every queued save — the daemon's last act on its way out, so a change
  /// applied a moment before `SIGTERM` is on disk when launchd restarts it.
  public nonisolated func flushPersistence() {
    writer.flush()
  }

  // MARK: - Connections

  /// What each connection announced it can read — see `DaemonCommand.announce`. Kept
  /// here, per connection, and handed to every store the connection joins, before or
  /// after the announcement arrives.
  private var connectionCapabilities: [UUID: Set<String>] = [:]

  public func addConnection(
    id: UUID,
    connection: any DaemonConnection,
    mode: DaemonProtocolMode = .v1,
    clientID: UUID? = nil,
    subscription: DaemonWireSubscription? = nil,
    replayStore: DaemonReplayStore? = nil
  ) async {
    let channel = DaemonConnectionChannel(
      connection: connection, mode: mode, clientID: clientID,
      subscription: subscription, replayStore: replayStore ?? self.replayStore)
    await addConnection(id: id, channel: channel)
  }

  public func addConnection(id: UUID, channel: DaemonConnectionChannel) async {
    connections[id] = channel
    if case .v2 = channel.mode,
      channel.authenticatedRemoteAssetOwner(clientID: channel.clientID) != nil
    {
      connectionClientIDs[id] = channel.clientID
    }
    // Reattach every persisted chat on reconnect. zmx's stable node ID makes this
    // idempotent when the previous daemon instance is still winding down.
    if let chats = try? quickChatStore.loadResult(), case .loaded(let loaded) = chats {
      for chat in loaded {
        _ = await ensureQuickChatSession(chat)
      }
      let known = Set(loaded.map(\.id))
      for orphan in await (enumerateQuickChatSessions?() ?? []) where !known.contains(orphan) {
        _ = await terminateQuickChatSession(
          QuickChat(id: orphan, title: "orphan", backend: .claudeCode))
      }
    }
    startPresencePolling()
  }

  #if canImport(Darwin) || canImport(Glibc)
    /// Compatibility seam for existing macOS callers; the registry stores only the
    /// channel abstraction after this boundary.
    public func addConnection(id: UUID, fileDescriptor: Int32) async {
      await addConnection(
        id: id,
        connection: UnixSocketConnection(
          id: id, fileDescriptor: fileDescriptor, bufferedWrites: true))
    }
  #endif

  public func removeConnection(_ id: UUID) async {
    let owner = remoteAssetOwner(for: id)
    let ownerStillConnected =
      owner.map { departingOwner in
        connections.keys.contains { connectionID in
          connectionID != id && remoteAssetOwner(for: connectionID) == departingOwner
        }
      } ?? false
    if let owner {
      await remoteAssets.disconnected(
        connectionID: id, owner: owner, ownerStillConnected: ownerStillConnected)
    }
    let preparing = preparingRelocations.filter { $0.value.connectionID == id }
    for (operationID, operation) in preparing {
      preparingRelocations.removeValue(forKey: operationID)
      sessionLaunchBarrier.endRelocation(
        path: operation.sourcePath, owner: operation.generation)
    }
    let abandoned = preparedRelocations.filter { _, prepared in
      guard prepared.connectionID == id else { return false }
      if case .prepared = prepared.phase { return true }
      return false
    }
    for (operationID, prepared) in abandoned {
      preparedRelocations.removeValue(forKey: operationID)
      if prepared.writerBlocked {
        writer.cancelRelocation(path: prepared.plan.sourcePath)
      }
      sessionLaunchBarrier.endRelocation(
        path: prepared.plan.sourcePath, owner: prepared.generation)
      await prepared.store.endRelocation()
    }
    for path in connectionProjectPaths[id] ?? [] {
      guard let store = stores[path] else { continue }
      await store.removeConnection(id)
    }
    let channel = connections.removeValue(forKey: id)
    connectionProjectPaths.removeValue(forKey: id)
    connectionClientIDs.removeValue(forKey: id)
    connectionCapabilities.removeValue(forKey: id)
    sidebarConnections.remove(id)
    if connections.isEmpty { stopPresencePolling() }
    try? await channel?.close()
  }

  private func remoteAssetOwner(for connectionID: UUID) -> UUID? {
    guard let channel = connections[connectionID],
      let clientID = connectionClientIDs[connectionID]
    else { return nil }
    return channel.authenticatedRemoteAssetOwner(clientID: clientID)
  }

  private static func attachmentCreateTarget(
    in command: GraphCommand,
    graph: LoopGraph
  ) -> Result<AttachmentCreateTarget?, AttachmentCreateAddressError> {
    var addressedCompositeIDs: [UUID] = []
    var inner = command
    while case .subGraphCommand(let nodeID, let command) = inner {
      addressedCompositeIDs.append(nodeID)
      inner = command
    }
    guard case .createNode(let draft) = inner else { return .success(nil) }

    var current = graph
    var resolvedPath: [UUID] = []
    for compositeID in addressedCompositeIDs {
      guard let resolved = graphAddressed(to: compositeID, from: current) else {
        return .failure(
          AttachmentCreateAddressError(
            message: "node creation refused: no composite \(compositeID) in this graph",
            draft: draft))
      }
      current = resolved.graph
      resolvedPath.append(contentsOf: resolved.path)
    }
    return .success(AttachmentCreateTarget(draft: draft, graphPath: resolvedPath))
  }

  private static func replacingCreateDraft(
    in command: GraphCommand, with draft: NodeDraft
  ) -> GraphCommand {
    switch command {
    case .createNode:
      return .createNode(draft)
    case .subGraphCommand(let nodeID, let nested):
      return .subGraphCommand(
        nodeID: nodeID, command: replacingCreateDraft(in: nested, with: draft))
    default:
      return command
    }
  }

  private static func containsNodeDeletion(_ command: GraphCommand) -> Bool {
    switch command {
    case .deleteNode:
      return true
    case .subGraphCommand(_, let nested):
      return containsNodeDeletion(nested)
    default:
      return false
    }
  }

  private static func graphAddressed(
    to compositeID: UUID,
    from root: LoopGraph
  ) -> (graph: LoopGraph, path: [UUID])? {
    var pending: [(graph: LoopGraph, path: [UUID])] = [(root, [])]
    while let candidate = pending.popLast() {
      if let node = candidate.graph.nodes[id: compositeID] {
        guard node.loopType == .composite, let child = node.subGraph else { return nil }
        return (child, candidate.path + [compositeID])
      }
      for node in candidate.graph.nodes.reversed()
      where node.loopType == .composite {
        guard let child = node.subGraph else { continue }
        pending.append((child, candidate.path + [node.id]))
      }
    }
    return nil
  }

  // MARK: - Presence polling

  /// How often a live session is asked what it is doing.
  ///
  /// The trade is plain: this is the lag between a loop finishing its turn and its card
  /// admitting it, and the cost is one `zmx get` per *unresolved loop* per tick. Not per
  /// app and not per project — per loop, because `zmx` has no way to read many sessions'
  /// labels at once (`list --where k=v` is in its help but returns every session whatever
  /// you filter on, so it cannot be used to batch this).
  ///
  /// Fifteen seconds keeps active work current. Once every loaded graph has no running
  /// loops, the poll backs off to a minute: terminal input can still wake a parked session
  /// without making a canvas full of stalled or completed loops expensive to leave open.
  static let presencePollInterval: Duration = .seconds(15)
  static let idlePresencePollInterval: Duration = .seconds(60)

  static func presencePollDelay(runningLoops: Int) -> Duration {
    runningLoops > 0 ? presencePollInterval : idlePresencePollInterval
  }

  private func presencePollDelay() async -> Duration {
    var running = 0
    for store in stores.values { running += await store.runningLoopCount() }
    return Self.presencePollDelay(runningLoops: running)
  }

  /// Polling runs only while a client is attached — see `GraphStore.pollPresence` for why
  /// the same guard is repeated per store. Started by the first connection and cancelled
  /// by the last, so a daemon running loops with no app open spends nothing on this.
  private func startPresencePolling() {
    guard presencePoller == nil, readPresence != nil else { return }
    presencePoller = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        try? await Task.sleep(for: await self.presencePollDelay())
        guard !Task.isCancelled else { return }
        await self.pollPresence()
      }
    }
  }

  private func stopPresencePolling() {
    presencePoller?.cancel()
    presencePoller = nil
  }

  // MARK: - Remote liveness

  /// How often a remote project's unattended sessions are checked for existence.
  ///
  /// Local loops need no such sweep: their sessions die with the machine, and the machine
  /// coming back restarts `graphcoded`, which loads the graph and calls
  /// `ensureUnattendedSessions`. A *remote* host reboots — a Codespace stops on idle and
  /// starts again — without this daemon restarting at all, so that one call site never
  /// fires and every loop on that host stays dead until the app is relaunched.
  ///
  /// Unlike the presence poll this runs with no client attached, because a loop being
  /// alive matters when nobody is watching and a reading does not. On a healthy tick the
  /// dial is a bare `zmx get` — `remoteEnsureInvocation` keeps the hooks write and the
  /// file delivery behind that check precisely so this can be cheap — multiplexed onto
  /// the host's existing `ControlMaster` connection.
  static let remoteLivenessSweepInterval: Duration = .seconds(60)

  /// Generous next to the remote sweep's minute: on a healthy machine the condemned
  /// list is empty and a tick is one file read, but a tick that finds work spawns
  /// processes, and a session that survived three confirmed kill attempts is not going
  /// to die to a faster clock.
  static let condemnedReapInterval: Duration = .seconds(300)

  private var remoteSweeper: Task<Void, Never>?
  private var condemnedReaper: Task<Void, Never>?

  /// Started by the first remote project this daemon loads and left running: a store is
  /// never removed for being idle, and the sweep costs nothing on a tick where no project
  /// is remote.
  private func startRemoteLivenessSweep() {
    guard remoteSweeper == nil, ensureSession != nil else { return }
    remoteSweeper = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.remoteLivenessSweepInterval)
        guard !Task.isCancelled else { return }
        await self?.sweepRemoteSessions()
      }
    }
  }

  /// The registry outlives the daemon in practice, but a `Task` holding only a weak
  /// `self` would otherwise keep waking every minute after the registry it sweeps for is
  /// gone — the same reason `GraphStore` cancels its goal pollers here.
  deinit {
    remoteSweeper?.cancel()
    condemnedReaper?.cancel()
    awakeRecheck?.cancel()
  }

  /// `GraphStore` invokes its ensure hook synchronously, while the registry tracks the
  /// resulting task through completion. This sweep still returns before those tasks
  /// finish; `RemoteEnsureGate` bounds the work to one ensure per node so a slow tick
  /// cannot pile a second dial onto the same session.
  private func sweepRemoteSessions() async {
    for (path, store) in stores where RemoteProjectLocation.parse(projectPath: path) != nil {
      await store.ensureUnattendedSessionsAlive()
    }
  }

  func ensureRemoteSessionsAlive() async {
    await sweepRemoteSessions()
  }

  /// Takes or drops the sleep assertion to match what is running right now
  /// (`AwakeAssertion`), across every open project.
  ///
  /// Called on every graph change rather than on a timer, because a graph change is
  /// exactly when the answer can differ. The one thing a graph change cannot notice is
  /// the *setting* being switched off while loops keep running, which is why holding the
  /// assertion also starts a slow re-check — and only while it is held, so a daemon with
  /// this switched off, or with nothing running, still keeps no timer at all.
  private func refreshAwakeAssertion() async {
    var running = 0
    for store in stores.values { running += await store.runningLoopCount() }
    let enabled = GraphcodeSettingsStore.load().keepsMacAwakeWhileLoopsRun
    let shouldHold = AwakeAssertion.shouldStayAwake(runningLoops: running, enabled: enabled)
    await AwakeAssertion.shared.apply(shouldHold: shouldHold, runningLoops: running)
    if shouldHold { startAwakeRecheck() } else { stopAwakeRecheck() }
  }

  static let awakeRecheckInterval: Duration = .seconds(60)

  private func startAwakeRecheck() {
    guard awakeRecheck == nil else { return }
    awakeRecheck = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.awakeRecheckInterval)
        guard !Task.isCancelled else { return }
        await self?.refreshAwakeAssertion()
      }
    }
  }

  private func stopAwakeRecheck() {
    awakeRecheck?.cancel()
    awakeRecheck = nil
  }

  /// Sequential rather than concurrent across projects: each store's poll already spawns
  /// one subprocess per loop, and firing every project's at once would turn a quiet
  /// background tick into a burst of them.
  private func pollPresence() async {
    for store in stores.values {
      await store.pollPresence()
    }
  }

  // MARK: - Commands

  public func handle(_ command: DaemonCommand, connectionID: UUID) async {
    guard let result = await apply(command, connectionID: connectionID),
      let message = result.error,
      let channel = connections[connectionID],
      case .v1 = channel.mode
    else { return }
    if case .graphCommand(let path, _) = command,
      stores[Self.canonicalize(path, platformPaths: platformPaths)] != nil
    {
      // GraphStore has already emitted this rejection to its v1 subscribers.
      return
    }
    await send(.errorOccurred(message), to: connectionID)
  }

  public func completeRemoteAssetDelivery(
    _ deliveryID: UUID,
    connectionID: UUID,
    delivered: Bool
  ) async {
    guard let owner = remoteAssetOwner(for: connectionID) else { return }
    if case .failure = await remoteAssets.completeDelivery(
      owner: owner, connectionID: connectionID, deliveryID: deliveryID, delivered: delivered)
    {
      DaemonLog.shared.record(
        "remote-asset-cleanup-failed",
        [("conn", connectionID.uuidString), ("delivery", deliveryID.uuidString)])
    }
  }

  /// Called by the daemon's session/activity poller. Sequence numbers are persisted with
  /// the chat so reconnecting clients can order updates deterministically.
  public func updateQuickChatActivity(
    id: UUID,
    text: String?,
    presence: PresenceReading?
  ) async -> Bool {
    guard let chat = quickChatStore.chat(id: id) else { return false }
    let sequence = (chat.activity?.sequence ?? 0) + 1
    let activity = QuickChatActivity(sequence: sequence, text: text, presence: presence)
    guard (try? quickChatStore.updateActivity(id: id, activity: activity)) != nil else {
      return false
    }
    await broadcast(.quickChatActivity(id: id, activity: activity))
    return true
  }

  /// Applies a command and snapshots its correlated result before returning to the
  /// daemon read loop. Keeping mutation and response selection together prevents a
  /// concurrent disconnect or command from turning a rejected mutation into a stale
  /// successful graph response.
  public func apply(
    _ command: DaemonCommand,
    connectionID: UUID
  ) async -> ProjectRegistryCommandResult? {
    guard let channel = connections[connectionID] else { return nil }
    let broadcastErrors: Bool
    if case .v2 = channel.mode {
      broadcastErrors = false
    } else {
      broadcastErrors = true
    }
    var response: DaemonEvent? = nil
    var error: String? = nil
    var errorCode: DaemonWireErrorCode? = nil

    switch command {
    case .listRecentProjects:
      let recentProjects = authoritativeRecentProjects()
      if case .v1 = channel.mode {
        await send(.recentProjectsListed(recentProjects), to: connectionID)
      }
      response = .recentProjectsListed(recentProjects)
      error = nil

    case .openProject(let path):
      switch routing(for: path, isSidebar: sidebarConnections.contains(connectionID)) {
      case .project(let canonicalPath):
        guard !isProjectRelocating(canonicalPath) else {
          return ProjectRegistryCommandResult(error: "project relocation is in progress")
        }
        let snapshot = await open(canonicalPath, for: connectionID, channel: channel)
        response = .graphChanged(snapshot)
        error = nil
      case .refused(let reason):
        error = reason
      }

    case .restoreOpenProjects:
      // Each of these broadcasts a `.graphChanged` exactly as `.openProject` would, so
      // the app reuses its ordinary "graph for a project I don't know yet = project
      // opened" path instead of needing a restore-shaped event of its own.
      //
      // Only the spelling is re-checked here, not whether the directory is there: these
      // paths were openable when they were added, and a project on an unmounted volume
      // has to come back when the volume does. Nothing is deleted from the stored set
      // either way — `close` is the only thing that removes from it.
      // Asking for the whole open set is what marks a client as a sidebar: from here on
      // it is joined to projects *other* clients open, so `graphcode status <new folder>`
      // puts a row in a running app instead of one that only appears next launch.
      sidebarConnections.insert(connectionID)
      for path in prunedOpenProjects()
      where Self.isWellFormedProjectPath(path, platformPaths: platformPaths) {
        let canonicalPath = Self.canonicalize(path, platformPaths: platformPaths)
        guard !isProjectRelocating(canonicalPath) else {
          return ProjectRegistryCommandResult(error: "project relocation is in progress")
        }
        _ = await open(canonicalPath, for: connectionID, channel: channel)
      }
      response = .recentProjectsListed(authoritativeRecentProjects())
      error = nil

    case .openGlobalGraph:
      let snapshot = await open(LoopGraphScope.globalPath, for: connectionID, channel: channel)
      response = .graphChanged(snapshot)
      error = nil

    case .closeProject(let path):
      let canonicalPath = Self.canonicalize(path, platformPaths: platformPaths)
      guard !isProjectRelocating(canonicalPath) else {
        return ProjectRegistryCommandResult(error: "project relocation is in progress")
      }
      let snapshot = await close(canonicalPath, for: connectionID)
      response = snapshot.map(DaemonEvent.graphChanged)
      error = nil

    case .forgetProject(let path):
      let canonicalPath = Self.canonicalize(path, platformPaths: platformPaths)
      guard !isProjectRelocating(canonicalPath) else {
        return ProjectRegistryCommandResult(error: "project relocation is in progress")
      }
      _ = await close(canonicalPath, for: connectionID)
      persistence.forgetProject(path: canonicalPath)
      if path != canonicalPath { persistence.forgetProject(path: path) }
      error = nil

    case .deleteProjectGraph(let path):
      let canonicalPath = Self.canonicalize(path, platformPaths: platformPaths)
      guard !isProjectRelocating(canonicalPath) else {
        return ProjectRegistryCommandResult(error: "project relocation is in progress")
      }
      // The graph is the only handle on every loop's detached session, so capture it
      // before durable deletion and end those sessions only after the graph file is
      // acknowledged absent. Read from the resident store when there is one, else
      // straight from disk: going through
      // `store(forProjectPath:)` would run its load-time `ensureUnattendedSessions`,
      // *starting* sessions on the way to killing them. Memory goes with each loop, the
      // same as single-node deletion.
      let graph = await stores[canonicalPath]?.graph ?? writer.load(path: canonicalPath)
      let metadata = graph?.project.metadata ?? classifyProject(canonicalPath)
      let deletionTransactionID: UUID?
      switch await remoteAssets.prepareDeletion(
        projectPath: canonicalPath, metadata: metadata,
        nodes: graph?.nodesAtAnyDepth ?? [], includeProjectState: true)
      {
      case .success(let transactionID):
        deletionTransactionID = transactionID
      case .failure(let failure):
        return ProjectRegistryCommandResult(
          error: failure.message, errorCode: Self.wireCode(for: failure))
      }
      do {
        try writer.deleteAcknowledged(path: canonicalPath)
      } catch {
        if let deletionTransactionID {
          _ = await remoteAssets.cancelDeletion(transactionID: deletionTransactionID)
        }
        return ProjectRegistryCommandResult(error: "graph deletion persistence failed: \(error)")
      }
      if let deletionTransactionID,
        case .failure = await remoteAssets.activateDeletion(
          transactionID: deletionTransactionID)
      {
        await broadcast(
          .errorOccurred(
            "project attachment cleanup is durably held and will resume after restart"))
      }
      _ = await close(canonicalPath, for: connectionID)
      persistence.forgetProject(path: canonicalPath)
      for node in graph?.nodesAtAnyDepth ?? [] {
        terminateSession?(node, canonicalPath)
        NodeMemory.remove(projectPath: canonicalPath, nodeID: node.id)
      }
      // Drop the in-memory store too, or a later reopen would resurrect the graph we
      // just deleted from the one still sitting in `stores`.
      stores.removeValue(forKey: canonicalPath)
      response = .recentProjectsListed(authoritativeRecentProjects())
      error = nil

    case .listQuickChats:
      guard let chats = try? quickChatStore.loadResult() else {
        error = "quick chat store is corrupt or unreadable"
        break
      }
      switch chats {
      case .missing: response = .quickChatsListed([])
      case .loaded(let values): response = .quickChatsListed(values)
      }
      await broadcast(response!)

    case .createQuickChat(let title, let backend):
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        error = "quick chat title must not be empty"
        break
      }
      let chat = QuickChat(title: trimmed, backend: backend)
      do {
        try quickChatStore.create(chat)
      } catch _ {
        error = "quick chat persistence failed"
        break
      }
      response = .quickChatChanged(chat)
      await broadcast(response!)

    case .openQuickChat(let id):
      guard let chat = quickChatStore.chat(id: id) else {
        error = "quick chat not found"
        break
      }
      switch await ensureQuickChatSession(chat) {
      case .failure(let failure):
        error = "quick chat session unavailable: \(failure)"
        break
      case .success:
        response = .quickChatChanged(chat)
        await broadcast(response!)
      }
      if error != nil { break }

    case .renameQuickChat(let id, let title):
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        error = "quick chat title must not be empty"
        break
      }
      guard let chat = (try? quickChatStore.rename(id: id, title: trimmed)) ?? nil else {
        error = "quick chat not found"
        break
      }
      response = .quickChatChanged(chat)
      await broadcast(response!)

    case .deleteQuickChat(let id):
      guard let chat = quickChatStore.chat(id: id) else {
        error = "quick chat not found"
        break
      }
      // Stop and confirm first. The record remains durable on failure so reconnect
      // can retry rather than leaving an untracked live session.
      guard case .success = await terminateQuickChatSession(chat) else {
        error = "quick chat session termination failed"
        break
      }
      do {
        _ = try quickChatStore.delete(id: id)
      } catch _ {
        _ = await ensureQuickChatSession(chat)
        error = "quick chat persistence failed"
        break
      }
      response = .quickChatDeleted(id)
      await broadcast(response!)

    case .loadSettings:
      guard case .v2 = channel.mode else {
        error = "shared settings requests require daemon protocol v2"
        break
      }
      do {
        response = .settingsChanged(try GraphcodeSettingsStore.snapshot(from: settingsURL))
      } catch let storeError as GraphcodeSettingsStore.StoreError {
        (errorCode, error) = Self.settingsError(storeError)
      } catch let caught {
        _ = caught
        errorCode = .settingsUnavailable
        error = "settings could not be loaded"
      }

    case .updateSettings(let expectedRevision, let settings):
      guard case .v2 = channel.mode else {
        error = "shared settings requests require daemon protocol v2"
        break
      }
      do {
        let snapshot = try GraphcodeSettingsStore.update(
          settings, expectedRevision: expectedRevision, at: settingsURL)
        response = .settingsChanged(snapshot)
        await broadcast(response!)
        await refreshAwakeAssertion()
      } catch let storeError as GraphcodeSettingsStore.StoreError {
        (errorCode, error) = Self.settingsError(storeError)
      } catch let caught {
        _ = caught
        errorCode = .settingsUnavailable
        error = "settings could not be saved"
      }

    case .openNodeSession(let path, let nodeID):
      switch routing(for: path, isSidebar: sidebarConnections.contains(connectionID)) {
      case .project(let canonicalPath):
        guard connectionProjectPaths[connectionID]?.contains(canonicalPath) == true,
          let store = stores[canonicalPath]
        else {
          return ProjectRegistryCommandResult(
            error: RemoteAssetError.unauthorized.message,
            errorCode: .remoteAssetUnauthorized)
        }
        guard !(await store.isRelocating) else {
          return ProjectRegistryCommandResult(error: "project relocation is in progress")
        }
        let graph = await store.graph
        guard let stored = graph.nodesAtAnyDepth.first(where: { $0.id == nodeID }) else {
          error = "loop session unavailable: no loop \(nodeID) in this graph"
          break
        }
        if let compatibilityError = Self.terminalCompatibilityError(project: graph.project) {
          error = compatibilityError
          break
        }
        if stored.runsUnattended {
          response = .graphChanged(await store.graph)
          break
        }
        guard let launchToken = sessionLaunchBarrier.beginLaunch(path: canonicalPath) else {
          error = "project relocation is in progress"
          break
        }
        defer { sessionLaunchBarrier.endLaunch(launchToken) }
        guard sessionLaunchBarrier.isCurrent(launchToken) else {
          error = "project relocation is in progress"
          break
        }
        guard let storedLaunchNode = await store.nodeForSessionLaunch(nodeID),
          let startNodeSession
        else {
          error = "loop session unavailable: session launcher unavailable"
          break
        }
        let metadata =
          graph.project.metadata ?? ProjectMetadata.inferred(fromProjectPath: canonicalPath)
        var launchNode: LoopNode?
        switch await preparedLaunchCopy(
          storedLaunchNode, projectPath: canonicalPath, metadata: metadata,
          authority: .connection(connectionID))
        {
        case .success(let copy):
          launchNode = copy
        case .failure(let failure):
          error = failure.message
          errorCode = Self.wireCode(for: failure)
        }
        guard let node = launchNode else { break }
        guard sessionLaunchBarrier.isCurrent(launchToken) else {
          error = "project relocation is in progress"
          break
        }
        let sessionExisted = await nodeSessionExists?(node, canonicalPath) == true
        guard sessionLaunchBarrier.isCurrent(launchToken) else {
          error = "project relocation is in progress"
          break
        }
        if !sessionExisted {
          let failure = await findMissingProvider?(node, canonicalPath)
          guard sessionLaunchBarrier.isCurrent(launchToken) else {
            error = "project relocation is in progress"
            break
          }
          let sessionAppeared = await nodeSessionExists?(node, canonicalPath) == true
          guard sessionLaunchBarrier.isCurrent(launchToken) else {
            error = "project relocation is in progress"
            break
          }
          if let failure, !sessionAppeared {
            error = "loop session unavailable: \(failure.title)"
            break
          }
        }
        let startResult = await startNodeSession(node, canonicalPath)
        guard sessionLaunchBarrier.isCurrent(launchToken) else {
          error = "project relocation is in progress"
          break
        }
        switch startResult {
        case .success:
          response = .graphChanged(await store.graph)
        case .failure(let failure):
          error = "loop session unavailable: \(Self.sessionErrorMessage(failure))"
        }
      case .refused(let reason):
        error = reason
      }

    case .graphCommand(let path, let inner):
      // Routed the same way the open was, so a client that had its path redirected to the
      // project containing it addresses that project here too. Without the second half,
      // the open would land on one graph and every command after it on nothing at all —
      // silently, which is how a `node create` could look like it hung.
      switch routing(for: path, isSidebar: sidebarConnections.contains(connectionID)) {
      case .project(let canonicalPath):
        guard connectionProjectPaths[connectionID]?.contains(canonicalPath) == true,
          let store = stores[canonicalPath]
        else {
          return ProjectRegistryCommandResult(
            error: RemoteAssetError.unauthorized.message,
            errorCode: .remoteAssetUnauthorized)
        }
        let authoritativeGraph = await store.graph
        let projectMetadata =
          authoritativeGraph.project.metadata
          ?? ProjectMetadata.inferred(fromProjectPath: canonicalPath)
        let createTarget: AttachmentCreateTarget?
        switch Self.attachmentCreateTarget(in: inner, graph: authoritativeGraph) {
        case .failure(let failure):
          let owner = remoteAssetOwner(for: connectionID) ?? connectionID
          _ = await remoteAssets.discardDraft(
            owner: owner, projectPath: canonicalPath, metadata: projectMetadata,
            nodeID: failure.draft.id)
          return ProjectRegistryCommandResult(error: failure.message)
        case .success(let target):
          createTarget = target
        }
        var createLeaseID: UUID?
        var deletionTransactionID: UUID?
        var commandToApply = inner
        if Self.containsNodeDeletion(inner) {
          let preview = await store.previewGraphChange(inner)
          guard case .applied(let projectedGraph) = preview else {
            if case .rejected(let message, _) = preview {
              return ProjectRegistryCommandResult(error: message)
            }
            return ProjectRegistryCommandResult(error: "node deletion could not be previewed")
          }
          let surviving = Set(projectedGraph.nodesAtAnyDepth.map(\.id))
          let removed = authoritativeGraph.nodesAtAnyDepth.filter { !surviving.contains($0.id) }
          switch await remoteAssets.prepareDeletion(
            projectPath: canonicalPath, metadata: projectMetadata, nodes: removed)
          {
          case .success(let transactionID):
            deletionTransactionID = transactionID
          case .failure(let failure):
            return ProjectRegistryCommandResult(
              error: failure.message, errorCode: Self.wireCode(for: failure))
          }
        }
        if let target = createTarget {
          let draft = target.draft
          guard authoritativeGraph.nodesAtAnyDepth.allSatisfy({ $0.id != draft.id }) else {
            return ProjectRegistryCommandResult(
              error: "node creation refused: a node with that id already exists")
          }
          let allowsLegacyLocalPaths: Bool
          if case .v1 = channel.mode {
            allowsLegacyLocalPaths = projectMetadata.location == .local
          } else {
            allowsLegacyLocalPaths = false
          }
          let owner = remoteAssetOwner(for: connectionID) ?? connectionID
          switch await remoteAssets.prepareCreate(
            draft.attachments, owner: owner, projectPath: canonicalPath,
            metadata: projectMetadata, nodeID: draft.id,
            allowsLegacyLocalPaths: allowsLegacyLocalPaths)
          {
          case .success(let leaseID):
            createLeaseID = leaseID
            if let leaseID {
              switch await remoteAssets.securedAttachments(
                leaseID: leaseID, attachments: draft.attachments)
              {
              case .success(let attachments):
                var securedDraft = draft
                securedDraft.attachments = attachments
                commandToApply = Self.replacingCreateDraft(
                  in: inner, with: securedDraft)
              case .failure(let failure):
                _ = await remoteAssets.rollbackCreate(leaseID: leaseID)
                return ProjectRegistryCommandResult(
                  error: failure.message, errorCode: Self.wireCode(for: failure))
              }
            }
          case .failure(let failure):
            _ = await remoteAssets.discardDraft(
              owner: owner, projectPath: canonicalPath, metadata: projectMetadata, nodeID: draft.id)
            return ProjectRegistryCommandResult(
              error: failure.message, errorCode: Self.wireCode(for: failure))
          }
        }
        let v2PayloadLimit: Int? =
          if case .v2 = channel.mode { FramedMessageIO.v2MaxPayloadBytes } else { nil }
        let requester: UUID? = if case .v1 = channel.mode { connectionID } else { nil }
        if let createLeaseID,
          case .failure(let failure) = await remoteAssets.verifyCreateLease(
            leaseID: createLeaseID)
        {
          _ = await remoteAssets.rollbackCreate(leaseID: createLeaseID)
          return ProjectRegistryCommandResult(
            error: failure.message, errorCode: Self.wireCode(for: failure))
        }
        let result = await store.handle(
          commandToApply, from: requester,
          serializeCommands: true,
          broadcastErrors: broadcastErrors,
          v2PayloadLimit: v2PayloadLimit,
          requiresDurablePersistence: createTarget != nil || Self.containsNodeDeletion(inner))
        switch result {
        case .applied(let graph):
          if let target = createTarget, let createLeaseID {
            let retainedNames = Set(target.draft.attachments.map(\.fileName))
            switch await remoteAssets.finalizeCreate(
              leaseID: createLeaseID, retainedNames: retainedNames)
            {
            case .success(let cleanupDeferred):
              if cleanupDeferred {
                await broadcast(
                  .errorOccurred(
                    "attachment draft cleanup is pending and will be retried automatically"))
              }
            case .failure(let failure):
              await broadcast(
                .errorOccurred("attachment ownership finalization failed: \(failure.message)"))
            }
          }
          if let deletionTransactionID,
            case .failure = await remoteAssets.activateDeletion(
              transactionID: deletionTransactionID)
          {
            await broadcast(
              .errorOccurred(
                "attachment deletion cleanup is durably held and will resume after restart"))
          }
          response = .graphChanged(graph)
          error = nil
        case .rejected(let message, _):
          if let deletionTransactionID {
            _ = await remoteAssets.cancelDeletion(transactionID: deletionTransactionID)
          }
          if let createLeaseID {
            if case .failure = await remoteAssets.rollbackCreate(leaseID: createLeaseID) {
              error = "\(message); attachment rollback cleanup is pending"
            } else {
              error = message
            }
          } else if let target = createTarget {
            let draft = target.draft
            let metadata =
              authoritativeGraph.project.metadata
              ?? ProjectMetadata.inferred(fromProjectPath: canonicalPath)
            let owner = remoteAssetOwner(for: connectionID) ?? connectionID
            _ = await remoteAssets.discardDraft(
              owner: owner, projectPath: canonicalPath, metadata: metadata, nodeID: draft.id)
            error = message
          } else {
            error = message
          }
        }
      case .refused(let reason):
        error = reason
      }

    case .transcript(let path, let query):
      guard case .v2 = channel.mode else {
        return ProjectRegistryCommandResult(
          error: "transcript reads require daemon protocol v2",
          errorCode: .transcriptUnauthorized)
      }
      switch routing(for: path, isSidebar: sidebarConnections.contains(connectionID)) {
      case .project(let canonicalPath):
        guard connectionProjectPaths[connectionID]?.contains(canonicalPath) == true,
          let store = stores[canonicalPath]
        else {
          return ProjectRegistryCommandResult(
            error: TranscriptReadError.unauthorized.message,
            errorCode: .transcriptUnauthorized)
        }
        let graph = await store.graph
        guard let node = graph.nodesAtAnyDepth.first(where: { $0.id == query.nodeID }) else {
          return ProjectRegistryCommandResult(
            error: TranscriptReadError.unauthorized.message,
            errorCode: .transcriptUnauthorized)
        }
        switch await readTranscript(node, canonicalPath, query) {
        case .success(let page):
          let event = DaemonEvent.transcriptPage(page)
          guard
            let encoded = try? JSONEncoder().encode(
              DaemonWireEnvelope.response(id: UUID(), event: event)),
            encoded.count <= FramedMessageIO.v2MaxPayloadBytes
          else {
            return ProjectRegistryCommandResult(
              error: TranscriptReadError.oversized.message,
              errorCode: .transcriptOversized)
          }
          response = event
        case .failure(let failure):
          return ProjectRegistryCommandResult(
            error: failure.message,
            errorCode: Self.wireCode(for: failure))
        }
      case .refused:
        return ProjectRegistryCommandResult(
          error: TranscriptReadError.unauthorized.message,
          errorCode: .transcriptUnauthorized)
      }

    case .nodeResource(let path, let query):
      guard case .v2 = channel.mode else {
        return ProjectRegistryCommandResult(
          error: "node memory reads require daemon protocol v2",
          errorCode: .nodeResourceUnauthorized)
      }
      switch routing(for: path, isSidebar: sidebarConnections.contains(connectionID)) {
      case .project(let canonicalPath):
        guard connectionProjectPaths[connectionID]?.contains(canonicalPath) == true,
          let store = stores[canonicalPath]
        else {
          return ProjectRegistryCommandResult(
            error: NodeResourceReadError.unauthorized.message,
            errorCode: .nodeResourceUnauthorized)
        }
        let graph = await store.graph
        guard graph.project.metadata?.capabilities.memoryReads == true,
          graph.project.path == canonicalPath,
          let node = graph.nodesAtAnyDepth.first(where: { $0.id == query.nodeID })
        else {
          return ProjectRegistryCommandResult(
            error: NodeResourceReadError.unauthorized.message,
            errorCode: .nodeResourceUnauthorized)
        }
        switch readNodeResource(node, canonicalPath, query) {
        case .success(let page):
          let event = DaemonEvent.nodeResourcePage(page)
          guard
            let encoded = try? JSONEncoder().encode(
              DaemonWireEnvelope.response(id: UUID(), event: event)),
            encoded.count <= FramedMessageIO.v2MaxPayloadBytes
          else {
            return ProjectRegistryCommandResult(
              error: NodeResourceReadError.oversized.message,
              errorCode: .nodeResourceOversized)
          }
          response = event
        case .failure(let failure):
          return ProjectRegistryCommandResult(
            error: failure.message,
            errorCode: Self.wireCode(for: failure))
        }
      case .refused:
        return ProjectRegistryCommandResult(
          error: NodeResourceReadError.unauthorized.message,
          errorCode: .nodeResourceUnauthorized)
      }

    case .listTemplates(let path, let query):
      guard case .v2 = channel.mode else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      guard let owner = remoteAssetOwner(for: connectionID) else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      guard
        case .project(let canonicalPath) = routing(
          for: path, isSidebar: sidebarConnections.contains(connectionID)),
        connectionProjectPaths[connectionID]?.contains(canonicalPath) == true,
        let store = stores[canonicalPath]
      else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      let graph = await store.graph
      guard graph.project.path == canonicalPath, let metadata = graph.project.metadata else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      switch await remoteAssets.listTemplates(
        owner: owner, projectPath: canonicalPath, metadata: metadata, query: query)
      {
      case .success(let list): response = .templateList(list)
      case .failure(let failure):
        return ProjectRegistryCommandResult(
          error: failure.message, errorCode: Self.wireCode(for: failure))
      }

    case .readTemplate(let path, let query):
      guard case .v2 = channel.mode else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      guard let owner = remoteAssetOwner(for: connectionID) else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      guard
        case .project(let canonicalPath) = routing(
          for: path, isSidebar: sidebarConnections.contains(connectionID)),
        connectionProjectPaths[connectionID]?.contains(canonicalPath) == true,
        let store = stores[canonicalPath]
      else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      let graph = await store.graph
      guard graph.project.path == canonicalPath, let metadata = graph.project.metadata else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      switch await remoteAssets.readTemplate(
        owner: owner, projectPath: canonicalPath, metadata: metadata, query: query)
      {
      case .success(let content): response = .templateContent(content)
      case .failure(let failure):
        return ProjectRegistryCommandResult(
          error: failure.message, errorCode: Self.wireCode(for: failure))
      }

    case .beginAttachmentUpload(let path, let nodeID, let declaration):
      guard case .v2 = channel.mode else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      guard let owner = remoteAssetOwner(for: connectionID) else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      guard
        case .project(let canonicalPath) = routing(
          for: path, isSidebar: sidebarConnections.contains(connectionID)),
        connectionProjectPaths[connectionID]?.contains(canonicalPath) == true,
        let store = stores[canonicalPath]
      else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      let graph = await store.graph
      guard graph.project.path == canonicalPath, let metadata = graph.project.metadata,
        graph.nodesAtAnyDepth.allSatisfy({ $0.id != nodeID })
      else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      switch await remoteAssets.beginUpload(
        owner: owner, connectionID: connectionID, projectPath: canonicalPath, metadata: metadata,
        nodeID: nodeID, declaration: declaration, existingCount: 0)
      {
      case .success(let ticket): response = .attachmentUploadBegan(ticket)
      case .failure(let failure):
        return ProjectRegistryCommandResult(
          error: failure.message, errorCode: Self.wireCode(for: failure))
      }

    case .uploadAttachmentChunk(let transferID, let offset, let data):
      guard case .v2 = channel.mode, let owner = remoteAssetOwner(for: connectionID),
        case .success(let context) = await remoteAssets.context(
          owner: owner, connectionID: connectionID, transferID: transferID),
        connectionProjectPaths[connectionID]?.contains(context.projectPath) == true
      else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      switch await remoteAssets.append(
        owner: owner, connectionID: connectionID, transferID: transferID, offset: offset, data: data
      )
      {
      case .success(let progress): response = .attachmentUploadProgress(progress)
      case .failure(let failure):
        return ProjectRegistryCommandResult(
          error: failure.message, errorCode: Self.wireCode(for: failure))
      }

    case .finalizeAttachmentUpload(let transferID):
      guard case .v2 = channel.mode, let owner = remoteAssetOwner(for: connectionID),
        case .success(let context) = await remoteAssets.context(
          owner: owner, connectionID: connectionID, transferID: transferID),
        connectionProjectPaths[connectionID]?.contains(context.projectPath) == true,
        let store = stores[context.projectPath]
      else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      let graph = await store.graph
      guard graph.nodesAtAnyDepth.allSatisfy({ $0.id != context.nodeID }) else {
        _ = await remoteAssets.cancel(
          owner: owner, connectionID: connectionID, transferID: transferID)
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      switch await remoteAssets.finalize(
        owner: owner, connectionID: connectionID, transferID: transferID)
      {
      case .success(let attachment):
        return ProjectRegistryCommandResult(
          response: .attachmentStaged(attachment),
          remoteAssetDeliveryID: transferID)
      case .failure(let failure):
        return ProjectRegistryCommandResult(
          error: failure.message, errorCode: Self.wireCode(for: failure))
      }

    case .cancelAttachmentUpload(let transferID):
      guard case .v2 = channel.mode, let owner = remoteAssetOwner(for: connectionID) else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      switch await remoteAssets.cancel(
        owner: owner, connectionID: connectionID, transferID: transferID)
      {
      case .success: break
      case .failure(let failure):
        return ProjectRegistryCommandResult(
          error: failure.message, errorCode: Self.wireCode(for: failure))
      }

    case .discardStagedAttachments(let path, let nodeID):
      guard let owner = remoteAssetOwner(for: connectionID) else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      guard
        case .project(let canonicalPath) = routing(
          for: path, isSidebar: sidebarConnections.contains(connectionID)),
        connectionProjectPaths[connectionID]?.contains(canonicalPath) == true,
        let store = stores[canonicalPath]
      else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      let graph = await store.graph
      guard graph.nodesAtAnyDepth.allSatisfy({ $0.id != nodeID }),
        let metadata = graph.project.metadata
      else {
        return ProjectRegistryCommandResult(
          error: RemoteAssetError.unauthorized.message, errorCode: .remoteAssetUnauthorized)
      }
      if case .failure(let failure) = await remoteAssets.discardDraft(
        owner: owner, projectPath: canonicalPath, metadata: metadata, nodeID: nodeID)
      {
        return ProjectRegistryCommandResult(
          error: failure.message, errorCode: Self.wireCode(for: failure))
      }

    case .prepareProjectRelocation(
      let operationID, let sourcePath, let destinationPath, let options):
      guard ProjectRelocationPlatform.isSupported else {
        return ProjectRegistryCommandResult(
          error: ProjectRelocationError.unsupported.localizedDescription,
          errorCode: .projectRelocationUnsupported)
      }
      guard case .v2 = channel.mode,
        connectionCapabilities[connectionID]?.contains(
          ClientCapability.projectRelocation.rawValue) == true
      else {
        return ProjectRegistryCommandResult(
          error: ProjectRelocationError.unauthorized.localizedDescription,
          errorCode: .projectRelocationUnauthorized)
      }
      guard preparingRelocations[operationID] == nil,
        preparedRelocations[operationID] == nil
      else {
        return ProjectRegistryCommandResult(
          error: ProjectRelocationError.duplicateConflict.localizedDescription,
          errorCode: .projectRelocationConflict)
      }
      var leasedStore: GraphStore?
      var ownsLaunchBarrier = false
      var preparationGeneration: UUID?
      var preparationPath: String?
      do {
        let preflight = try relocationProject(
          sourcePath: sourcePath,
          connectionID: connectionID)
        guard
          !preparingRelocations.values.contains(where: { $0.sourcePath == preflight.path }),
          !preparedRelocations.values.contains(where: { $0.plan.sourcePath == preflight.path })
        else {
          throw ProjectRelocationError.preflightFailed
        }
        let generation = UUID()
        preparationGeneration = generation
        preparationPath = preflight.path
        preparingRelocations[operationID] = PreparingRelocation(
          connectionID: connectionID,
          sourcePath: preflight.path,
          generation: generation)
        guard
          await sessionLaunchBarrier.beginRelocation(
            path: preflight.path, owner: generation)
        else {
          throw ProjectRelocationError.preflightFailed
        }
        ownsLaunchBarrier = true
        try requirePreparing(
          operationID: operationID,
          connectionID: connectionID,
          generation: generation)
        let snapshot = await preflight.store.relocationSnapshot()
        try requirePreparing(
          operationID: operationID,
          connectionID: connectionID,
          generation: generation)
        guard
          let stableGraph = await preflight.store.beginRelocation(
            expectedRevision: snapshot.revision)
        else {
          throw ProjectRelocationError.graphRevisionChanged
        }
        leasedStore = preflight.store
        try requirePreparing(
          operationID: operationID,
          connectionID: connectionID,
          generation: generation)
        try await validateRelocationDependents(
          graph: stableGraph,
          path: preflight.path,
          revalidate: {
            try self.requirePreparing(
              operationID: operationID,
              connectionID: connectionID,
              generation: generation)
          })
        try requirePreparing(
          operationID: operationID,
          connectionID: connectionID,
          generation: generation)
        let plan = try relocationCoordinator.prepare(
          operationID: operationID,
          sourcePath: preflight.path,
          destinationPath: destinationPath,
          graphRevision: snapshot.revision,
          options: options,
          persistence: persistence)
        try requirePreparing(
          operationID: operationID,
          connectionID: connectionID,
          generation: generation)
        preparingRelocations.removeValue(forKey: operationID)
        preparedRelocations[operationID] = PreparedRelocation(
          connectionID: connectionID,
          clientID: channel.clientID,
          plan: plan,
          options: options,
          graph: stableGraph,
          store: preflight.store,
          generation: generation,
          phase: .prepared,
          writerBlocked: false)
        ownsLaunchBarrier = false
        response = .projectRelocationPrepared(plan)
      } catch let failure as ProjectRelocationError {
        if let preparationGeneration,
          preparingRelocations[operationID]?.generation == preparationGeneration
        {
          preparingRelocations.removeValue(forKey: operationID)
        }
        if ownsLaunchBarrier, let preparationGeneration, let preparationPath {
          sessionLaunchBarrier.endRelocation(
            path: preparationPath, owner: preparationGeneration)
        }
        if let leasedStore { await leasedStore.endRelocation() }
        return ProjectRegistryCommandResult(
          error: failure.localizedDescription, errorCode: Self.wireCode(for: failure))
      } catch {
        if let preparationGeneration,
          preparingRelocations[operationID]?.generation == preparationGeneration
        {
          preparingRelocations.removeValue(forKey: operationID)
        }
        if ownsLaunchBarrier, let preparationGeneration, let preparationPath {
          sessionLaunchBarrier.endRelocation(
            path: preparationPath, owner: preparationGeneration)
        }
        if let leasedStore { await leasedStore.endRelocation() }
        return ProjectRegistryCommandResult(
          error: ProjectRelocationError.preflightFailed.localizedDescription,
          errorCode: .projectRelocationPreflight)
      }

    case .relocateProject(let request):
      guard ProjectRelocationPlatform.isSupported else {
        return ProjectRegistryCommandResult(
          error: ProjectRelocationError.unsupported.localizedDescription,
          errorCode: .projectRelocationUnsupported)
      }
      guard case .v2 = channel.mode,
        connectionCapabilities[connectionID]?.contains(
          ClientCapability.projectRelocation.rawValue) == true
      else {
        return ProjectRegistryCommandResult(
          error: ProjectRelocationError.unauthorized.localizedDescription,
          errorCode: .projectRelocationUnauthorized)
      }
      var commitGeneration: UUID?
      do {
        let clientID = channel.clientID
        if let replay = try relocationCoordinator.replayResult(
          for: request, authorizedClientID: clientID)
        {
          return ProjectRegistryCommandResult(response: .projectRelocated(replay))
        }
        guard let prepared = preparedRelocations[request.operationID],
          prepared.connectionID == connectionID,
          case .prepared = prepared.phase
        else {
          throw ProjectRelocationError.unauthorized
        }
        let expectedRequest = ProjectRelocationRequest(
          operationID: prepared.plan.operationID,
          sourcePath: prepared.plan.sourcePath,
          destinationPath: prepared.plan.destinationPath,
          expectedSourceIdentity: prepared.plan.sourceIdentity,
          expectedGraphRevision: prepared.plan.graphRevision,
          options: prepared.options)
        guard request == expectedRequest else {
          throw ProjectRelocationError.duplicateConflict
        }
        let generation = UUID()
        commitGeneration = generation
        preparedRelocations[request.operationID]?.phase = .committing(generation)
        try await validateRelocationDependents(
          graph: prepared.graph,
          path: prepared.plan.sourcePath,
          revalidate: {
            try self.requireCommitting(
              operationID: request.operationID,
              connectionID: connectionID,
              generation: generation)
          })
        try requireCommitting(
          operationID: request.operationID,
          connectionID: connectionID,
          generation: generation)
        writer.beginRelocation(path: prepared.plan.sourcePath)
        preparedRelocations[request.operationID]?.writerBlocked = true
        try requireCommitting(
          operationID: request.operationID,
          connectionID: connectionID,
          generation: generation)
        try await validateRelocationDependents(
          graph: prepared.graph,
          path: prepared.plan.sourcePath,
          revalidate: {
            try self.requireCommitting(
              operationID: request.operationID,
              connectionID: connectionID,
              generation: generation)
          })
        try requireCommitting(
          operationID: request.operationID,
          connectionID: connectionID,
          generation: generation)
        let result = try relocationCoordinator.relocate(
          request,
          authorizedClientID: prepared.clientID,
          graph: prepared.graph,
          persistence: persistence)
        try await convergeRelocation(
          result,
          oldStore: prepared.store,
          requestingConnection: connectionID,
          revalidate: {
            try self.requireCommitting(
              operationID: request.operationID,
              connectionID: connectionID,
              generation: generation)
          })
        try requireCommitting(
          operationID: request.operationID,
          connectionID: connectionID,
          generation: generation)
        await finishRelocation(
          operationID: request.operationID,
          generation: generation)
        return ProjectRegistryCommandResult(
          response: .projectRelocated(result),
          closeConnectionAfterResponse: result.recoveryRequired)
      } catch let failure as ProjectRelocationError {
        await finishRelocation(
          operationID: request.operationID,
          connectionID: connectionID,
          generation: commitGeneration)
        return ProjectRegistryCommandResult(
          error: failure.localizedDescription, errorCode: Self.wireCode(for: failure))
      } catch {
        await finishRelocation(
          operationID: request.operationID,
          connectionID: connectionID,
          generation: commitGeneration)
        return ProjectRegistryCommandResult(
          error: ProjectRelocationError.preflightFailed.localizedDescription,
          errorCode: .projectRelocationPreflight)
      }

    case .announce(let capabilities, let clientID):
      if let clientID {
        guard channel.authenticatedRemoteAssetOwner(clientID: clientID) != nil,
          connectionClientIDs[connectionID].map({ $0 == clientID }) ?? true,
          {
            if case .v2 = channel.mode { return channel.clientID == clientID }
            return true
          }()
        else {
          return ProjectRegistryCommandResult(
            error: RemoteAssetError.unauthorized.message,
            errorCode: .remoteAssetUnauthorized)
        }
        connectionClientIDs[connectionID] = clientID
      }
      // Reaches every store this connection has already joined too: the app's launch
      // sends its joins and its announcement together, and which lands first must not
      // decide what the client is sent.
      let announced = Set(capabilities)
      connectionCapabilities[connectionID] = announced
      for path in connectionProjectPaths[connectionID] ?? [] {
        await stores[path]?.setCapabilities(announced, for: connectionID)
      }
      response = nil
      error = nil

    case .mailbox(let path, let query):
      // Routed and gated exactly as a `.graphCommand`: the room belongs to the project
      // the open landed on, and a query against a project this connection never
      // opened is answered the way a command against one is.
      switch routing(for: path, isSidebar: sidebarConnections.contains(connectionID)) {
      case .project(let canonicalPath):
        guard let store = stores[canonicalPath] else {
          return ProjectRegistryCommandResult(error: "\(path) isn't open — open it first.")
        }
        do {
          let event = DaemonEvent.mailbox(
            projectPath: canonicalPath, mailbox: try await store.mailbox(query))
          if case .v1 = channel.mode {
            await send(event, to: connectionID)
          }
          response = event
          error = nil
        } catch let refusal as GraphStore.MailboxRefusal {
          error = refusal.message
        } catch let caught {
          error = "\(caught)"
        }
      case .refused(let reason):
        error = reason
      }
    }

    return ProjectRegistryCommandResult(
      response: error == nil ? response : nil, error: error, errorCode: errorCode)
  }

  /// Produces a correlated v2 response after the command has been applied. The v1
  /// protocol continues to use its existing broadcast-only acknowledgement path.
  public func responseEvent(for command: DaemonCommand) async -> DaemonEvent? {
    switch command {
    case .listRecentProjects:
      return .recentProjectsListed(authoritativeRecentProjects())
    case .restoreOpenProjects:
      return .recentProjectsListed(authoritativeRecentProjects())
    case .openProject(let path), .closeProject(let path), .forgetProject(let path):
      let canonical = Self.canonicalize(path, platformPaths: platformPaths)
      guard let store = stores[canonical] else { return nil }
      return .graphChanged(await store.graph)
    case .deleteProjectGraph:
      return .recentProjectsListed(authoritativeRecentProjects())
    case .listQuickChats:
      guard let chats = try? quickChatStore.loadResult() else { return nil }
      switch chats {
      case .missing: return .quickChatsListed([])
      case .loaded(let values): return .quickChatsListed(values)
      }
    case .createQuickChat, .openQuickChat, .renameQuickChat:
      return nil
    case .deleteQuickChat(let id):
      return .quickChatDeleted(id)
    case .loadSettings:
      return (try? GraphcodeSettingsStore.snapshot(from: settingsURL))
        .map(DaemonEvent.settingsChanged)
    case .updateSettings:
      return nil
    case .openNodeSession(let path, _):
      guard let store = stores[Self.canonicalize(path, platformPaths: platformPaths)] else {
        return nil
      }
      return .graphChanged(await store.graph)
    case .openGlobalGraph:
      guard let store = stores[LoopGraphScope.globalPath] else { return nil }
      return .graphChanged(await store.graph)
    case .graphCommand(let path, _):
      guard let store = stores[Self.canonicalize(path, platformPaths: platformPaths)] else {
        return nil
      }
      return .graphChanged(await store.graph)
    case .announce, .mailbox, .transcript, .nodeResource, .listTemplates,
      .readTemplate,
      .beginAttachmentUpload, .uploadAttachmentChunk, .finalizeAttachmentUpload,
      .cancelAttachmentUpload, .discardStagedAttachments, .prepareProjectRelocation,
      .relocateProject:
      return nil
    }
  }

  private static func settingsError(
    _ error: GraphcodeSettingsStore.StoreError
  ) -> (DaemonWireErrorCode, String) {
    switch error {
    case .conflict(let currentRevision):
      return (
        .settingsConflict,
        "settings changed in another client; reload revision \(currentRevision) and try again"
      )
    case .corrupt, .invalidShape:
      return (
        .settingsCorrupt,
        "settings.json is corrupt; fix or restore the file, then reload without replacing it"
      )
    case .payloadTooLarge:
      return (
        .settingsPayloadTooLarge,
        "settings.json exceeds the bounded shared-settings payload limit"
      )
    case .unreadable, .encodingFailed, .writeFailed:
      return (.settingsUnavailable, "settings.json could not be read or saved")
    }
  }

  private static func wireCode(for error: ProjectRelocationError) -> DaemonWireErrorCode {
    switch error {
    case .unauthorized: return .projectRelocationUnauthorized
    case .unsupported: return .projectRelocationUnsupported
    case .sourceMissing: return .projectRelocationSourceMissing
    case .sourceIdentityChanged: return .projectRelocationIdentityChanged
    case .graphRevisionChanged: return .projectRelocationRevisionChanged
    case .activeSessions: return .projectRelocationActiveSessions
    case .activeWorktrees: return .projectRelocationActiveWorktrees
    case .destinationCollision: return .projectRelocationDestinationCollision
    case .unsafePath: return .projectRelocationUnsafePath
    case .crossVolume: return .projectRelocationCrossVolume
    case .permissionDenied: return .projectRelocationPermission
    case .preflightFailed: return .projectRelocationPreflight
    case .rolledBack, .rollbackFailed: return .projectRelocationRollback
    case .recoveryFailed: return .projectRelocationRecovery
    case .duplicateConflict: return .projectRelocationConflict
    case .transportFailure: return .transportFailure
    }
  }

  private func relocationProject(
    sourcePath: String,
    connectionID: UUID
  ) throws -> (path: String, store: GraphStore) {
    guard ProjectRelocationPlatform.isSupported else {
      throw ProjectRelocationError.unsupported
    }
    guard Self.isWellFormedProjectPath(sourcePath, platformPaths: platformPaths) else {
      throw ProjectRelocationError.unsafePath
    }
    let path = Self.canonicalize(sourcePath, platformPaths: platformPaths)
    guard connectionProjectPaths[connectionID]?.contains(path) == true else {
      throw ProjectRelocationError.unauthorized
    }
    let metadata = classifyProject(path)
    guard metadata.location == .local, metadata.capabilities.projectRelocation else {
      throw ProjectRelocationError.unsupported
    }
    guard let store = stores[path] else {
      throw ProjectRelocationError.preflightFailed
    }
    return (path, store)
  }

  private func validateRelocationDependents(
    graph: LoopGraph,
    path: String,
    revalidate: () throws -> Void = {}
  ) async throws {
    guard graph.nodesAtAnyDepth.allSatisfy({ $0.worktreeBinding == nil }) else {
      throw ProjectRelocationError.activeWorktrees
    }
    guard let nodeSessionExists else {
      throw ProjectRelocationError.preflightFailed
    }
    for node in graph.nodesAtAnyDepth {
      let exists = await nodeSessionExists(node, path)
      try revalidate()
      if exists {
        throw ProjectRelocationError.activeSessions
      }
    }
  }

  private func requirePreparing(
    operationID: UUID,
    connectionID: UUID,
    generation: UUID
  ) throws {
    guard let preparing = preparingRelocations[operationID],
      preparing.connectionID == connectionID,
      preparing.generation == generation
    else {
      throw ProjectRelocationError.unauthorized
    }
  }

  private func requireCommitting(
    operationID: UUID,
    connectionID: UUID,
    generation: UUID
  ) throws {
    guard let prepared = preparedRelocations[operationID],
      prepared.connectionID == connectionID,
      case .committing(let currentGeneration) = prepared.phase,
      currentGeneration == generation
    else {
      throw ProjectRelocationError.unauthorized
    }
  }

  private func finishRelocation(
    operationID: UUID,
    connectionID: UUID? = nil,
    generation: UUID? = nil
  ) async {
    guard let prepared = preparedRelocations[operationID] else { return }
    if let connectionID, prepared.connectionID != connectionID { return }
    if let generation {
      guard case .committing(let currentGeneration) = prepared.phase,
        currentGeneration == generation
      else { return }
    } else if connectionID != nil {
      guard case .prepared = prepared.phase else { return }
    }
    preparedRelocations.removeValue(forKey: operationID)
    if prepared.writerBlocked {
      writer.cancelRelocation(path: prepared.plan.sourcePath)
    }
    sessionLaunchBarrier.endRelocation(
      path: prepared.plan.sourcePath, owner: prepared.generation)
    await prepared.store.endRelocation()
  }

  private func isProjectRelocating(_ path: String) -> Bool {
    preparingRelocations.values.contains { $0.sourcePath == path }
      || preparedRelocations.values.contains { $0.plan.sourcePath == path }
  }

  private func convergeRelocation(
    _ result: ProjectRelocationResult,
    oldStore: GraphStore,
    requestingConnection: UUID,
    revalidate: () throws -> Void
  ) async throws {
    let affected = connectionProjectPaths.compactMap { id, paths in
      paths.contains(result.sourcePath) ? id : nil
    }
    stores.removeValue(forKey: result.sourcePath)
    writer.forget(path: result.sourcePath)
    let event = DaemonEvent.projectRelocated(result)

    if result.recoveryRequired {
      for id in affected where id != requestingConnection {
        await removeConnection(id)
        try revalidate()
      }
      return
    }

    let newStore = await store(forProjectPath: result.destinationPath, ensuringSessions: false)
    try revalidate()
    for id in affected {
      guard
        connectionCapabilities[id]?.contains(
          ClientCapability.projectRelocation.rawValue) == true,
        let channel = connections[id]
      else {
        await removeConnection(id)
        try revalidate()
        continue
      }
      await send(event, to: id)
      try revalidate()
      _ = await oldStore.removeConnection(id, leaveReplay: true)
      try revalidate()
      connectionProjectPaths[id]?.remove(result.sourcePath)
      connectionProjectPaths[id, default: []].insert(result.destinationPath)
      _ = await newStore.addConnection(
        id: id,
        channel: channel,
        capabilities: connectionCapabilities[id] ?? [])
      try revalidate()
    }
  }

  private static func wireCode(for error: TranscriptReadError) -> DaemonWireErrorCode {
    switch error {
    case .unauthorized: return .transcriptUnauthorized
    case .missing: return .transcriptMissing
    case .corrupt: return .transcriptCorrupt
    case .oversized: return .transcriptOversized
    case .invalidBounds: return .transcriptInvalidBounds
    case .invalidCursor: return .transcriptInvalidCursor
    case .unsupportedProvider: return .transcriptUnsupportedProvider
    case .transportFailure: return .transcriptTransportFailure
    }
  }

  private static func wireCode(for error: NodeResourceReadError) -> DaemonWireErrorCode {
    switch error {
    case .unauthorized: return .nodeResourceUnauthorized
    case .missing: return .nodeResourceMissing
    case .corrupt: return .nodeResourceCorrupt
    case .oversized: return .nodeResourceOversized
    case .invalidBounds: return .nodeResourceInvalidBounds
    case .invalidCursor: return .nodeResourceInvalidCursor
    case .unsupportedResource: return .nodeResourceUnsupportedResource
    case .transportFailure: return .nodeResourceTransportFailure
    }
  }

  private static func wireCode(for error: RemoteAssetError) -> DaemonWireErrorCode {
    switch error {
    case .unauthorized: return .remoteAssetUnauthorized
    case .unsupported: return .remoteAssetUnsupported
    case .invalidBounds: return .remoteAssetInvalidBounds
    case .invalidDeclaration: return .remoteAssetInvalidDeclaration
    case .tooManyAttachments: return .remoteAssetTooManyAttachments
    case .resourceExhausted: return .remoteAssetResourceExhausted
    case .unknownTransfer: return .remoteAssetUnknownTransfer
    case .expiredTransfer: return .remoteAssetExpiredTransfer
    case .invalidOffset: return .remoteAssetInvalidOffset
    case .oversized: return .remoteAssetOversized
    case .hashMismatch: return .remoteAssetHashMismatch
    case .invalidReference: return .remoteAssetInvalidReference
    case .ambiguousTemplate: return .remoteAssetAmbiguousTemplate
    case .missing: return .remoteAssetMissing
    case .unsafeFile: return .remoteAssetUnsafeFile
    case .transportFailure: return .remoteAssetTransportFailure
    }
  }

  private static func sessionErrorMessage(_ error: CLISessionError) -> String {
    switch error {
    case .unavailable(let message), .failed(let message): return message
    case .notFound: return "session not found"
    }
  }

  static func terminalCompatibilityError(project: ProjectRef) -> String? {
    if project.path == LoopGraphScope.globalPath { return nil }
    guard project.metadata?.capabilities.interactiveTerminals != true else { return nil }
    return
      "interactive terminals are not supported for this project; no session was started"
  }

  private func open(
    _ canonicalPath: String, for connectionID: UUID, channel: DaemonConnectionChannel
  ) async -> LoopGraph {
    let store = await store(forProjectPath: canonicalPath)
    if canonicalPath != LoopGraphScope.globalPath {
      let graph = await store.graph
      let metadata =
        graph.project.metadata ?? ProjectMetadata.inferred(fromProjectPath: canonicalPath)
      await remoteAssets.reconcile(
        projectPath: canonicalPath, metadata: metadata,
        graphNodeIDs: Set(graph.nodesAtAnyDepth.map(\.id)))
    }
    connectionProjectPaths[connectionID, default: []].insert(canonicalPath)
    let snapshot = await store.addConnection(id: connectionID, channel: channel)
    await store.setCapabilities(connectionCapabilities[connectionID] ?? [], for: connectionID)
    // The global graph is always resident and isn't a folder anyone opened, so it stays
    // out of both the recents list and the restore-on-launch set — the app asks for it
    // by name every launch instead.
    guard canonicalPath != LoopGraphScope.globalPath else { return snapshot }
    let project = snapshot.project
    persistence.recordOpened(
      ProjectRef(
        path: project.path,
        name: project.name,
        lastOpenedAt: Date(),
        metadata: project.metadata))
    guard rememberOpen(canonicalPath) else { return snapshot }
    await joinSidebars(to: store, at: canonicalPath, excluding: connectionID)
    return snapshot
  }

  private func recoverRemoteAssetsAtStartup() async {
    var projects: [String: (ProjectMetadata, Set<UUID>)] = [:]
    for graph in persistence.loadStoredGraphs()
    where graph.project.path != LoopGraphScope.globalPath {
      let metadata = graph.project.metadata ?? classifyProject(graph.project.path)
      projects[graph.project.path] = (metadata, Set(graph.nodesAtAnyDepth.map(\.id)))
    }
    for project in persistence.loadRecentProjects()
    where project.path != LoopGraphScope.globalPath && projects[project.path] == nil {
      projects[project.path] = (project.metadata ?? classifyProject(project.path), [])
    }
    for path in persistence.loadOpenProjects()
    where path != LoopGraphScope.globalPath && projects[path] == nil {
      projects[path] = (classifyProject(path), [])
    }
    for (path, value) in projects {
      await remoteAssets.reconcile(
        projectPath: path, metadata: value.0, graphNodeIDs: value.1)
    }
    await remoteAssets.maintainRecoveredState()
  }

  /// Joins every attached sidebar client to a project one of *them* — or the CLI, or a
  /// plugin driving it — just added to the open set, so it arrives as an ordinary
  /// `.graphChanged` snapshot.
  ///
  /// The open set is one shared list, not a per-connection view: `graphcode status
  /// <folder>` persists the folder for everyone, and every sidebar restores the same set
  /// at launch. Without this that shared list only reached a *running* app on relaunch,
  /// which is precisely how a folder added from outside the app looked like it hadn't
  /// been added at all.
  ///
  /// Only sidebars, and only on the open that was new. A one-shot CLI connection reads
  /// frames until the `.graphChanged` for the project it named (`runAndPrintGraph`, and
  /// the same loop in the remote python shim), so joining it to an unrelated project
  /// would hand it another project's graph to print.
  private func joinSidebars(to store: GraphStore, at path: String, excluding opener: UUID) async {
    for id in sidebarConnections where id != opener {
      guard let channel = connections[id] else { continue }
      connectionProjectPaths[id, default: []].insert(path)
      _ = await store.addConnection(id: id, channel: channel)
      await store.setCapabilities(connectionCapabilities[id] ?? [], for: id)
    }
  }

  private func close(_ canonicalPath: String, for connectionID: UUID) async -> LoopGraph? {
    var snapshot: LoopGraph?
    if let store = stores[canonicalPath] {
      snapshot = await store.removeConnection(connectionID, leaveReplay: true)
    }
    connectionProjectPaths[connectionID]?.remove(canonicalPath)
    // Compared canonically, not literally: a project added before remote paths were
    // normalized is stored under the spelling it arrived with, and closing it sends that
    // spelling back through `canonicalize`. Filtering on the raw string left those rows
    // in the open set and un-closable.
    persistence.saveOpenProjects(
      persistence.loadOpenProjects().filter {
        Self.canonicalize($0, platformPaths: platformPaths) != canonicalPath
      })
    return snapshot
  }

  /// Clears out the empty twins a pre-normalization daemon left in the sidebar: a stored
  /// path that is only another stored path spelled differently — a trailing slash, a
  /// doubled separator — and whose graph never received a loop or a board post.
  ///
  /// Deliberately timid. A twin with anything in it is left exactly where it is: it is
  /// somebody's work, and folding it into the project it duplicates would make those
  /// loops vanish rather than be found. Its graph file is kept either way; only the
  /// sidebar entry and the recents row go, and re-opening the path brings both back.
  private func prunedOpenProjects() -> [String] {
    let stored = persistence.loadOpenProjects()
    let kept = stored.filter { path in
      let canonical = Self.canonicalize(path, platformPaths: platformPaths)
      // Only ever a *later* twin, so the first spelling of a project always survives even
      // when every stored spelling of it is a variant.
      guard path != canonical,
        stored.prefix(while: { $0 != path }).contains(where: {
          Self.canonicalize($0, platformPaths: platformPaths) == canonical
        })
      else { return true }
      let graph = writer.load(path: path)
      let isEmpty = (graph?.nodesAtAnyDepth.isEmpty ?? true) && (graph?.mailroom.isEmpty ?? true)
      if isEmpty { persistence.forgetProject(path: path) }
      return !isEmpty
    }
    if kept != stored { persistence.saveOpenProjects(kept) }
    return kept
  }

  /// Append rather than insert-at-front: the sidebar should come back in the order it
  /// was built up, not most-recent-first — that's what the recents list is for.
  ///
  /// Returns whether this was the open that added the project, which is what tells
  /// `open` there is news to push to the other sidebars: a re-open of something already
  /// in the set (every restored project, every `graphcode status` on a folder the app is
  /// already showing) is not.
  @discardableResult
  private func rememberOpen(_ canonicalPath: String) -> Bool {
    var open = persistence.loadOpenProjects()
    guard !open.contains(canonicalPath) else { return false }
    open.append(canonicalPath)
    persistence.saveOpenProjects(open)
    return true
  }

  // MARK: - Which project a named path belongs to

  enum PathRouting: Equatable {
    case project(String)
    case refused(String)
  }

  /// Where a path a client named should be routed, and whether it may become a *new*
  /// project rather than an existing one.
  ///
  /// Opening is create-if-missing, because that is how a folder becomes a project at all:
  /// `graphcode status <folder>` from a shell is a supported way to add one. What that
  /// missed is that most paths a *loop* names are not new projects — they are its own
  /// worktree, its working directory, or its project's path spelled slightly differently.
  /// Each of those quietly became a second project: its own graph, its own recents entry,
  /// its own row in the sidebar under the same name, with the loops the agent then created
  /// inside it where nobody was looking. A codespace made it trivial to hit, since a
  /// remote path is never checked against a filesystem: every spelling of one was openable.
  ///
  /// So two kinds of path are never a new project when a shell client names them:
  ///
  /// - **A folder inside a project that already exists** is that project — a worktree
  ///   under the repository, a subdirectory, the remote path of a codespace already added.
  /// - **A remote path this daemon has never seen.** Remote projects are added in the app,
  ///   which validates the connection over ssh first; nothing typed at a shell can be
  ///   checked that way, so an unknown one is a typo or a spelling variant of a known one.
  ///
  /// The app is exempt from both, and is told apart by having asked for the whole open set
  /// (`sidebarConnections`): opening a nested folder or adding a remote host is a
  /// deliberate human act there, and refusing it would break Add Folder.
  func routing(for path: String, isSidebar: Bool) -> PathRouting {
    guard Self.isWellFormedProjectPath(path, platformPaths: platformPaths) else {
      return .refused(
        "\(path) isn't a project path — name an absolute folder, an ssh:// or codespace:// "
          + "project, or \(LoopGraphScope.globalPath).")
    }
    let canonicalPath = Self.canonicalize(path, platformPaths: platformPaths)
    guard canonicalPath != LoopGraphScope.globalPath else { return .project(canonicalPath) }
    let known = knownProjectPaths()
    if known.contains(canonicalPath) { return .project(canonicalPath) }
    if !isSidebar, let container = Self.project(containing: canonicalPath, in: known) {
      return .project(container)
    }
    if RemoteProjectLocation.parse(projectPath: canonicalPath) != nil {
      #if os(Windows)
        return .project(canonicalPath)
      #else
        guard isSidebar else {
          return .refused(
            "graphcode doesn't know a project at \(canonicalPath). Run `graphcode projects` "
              + "for the exact path; a remote repository or codespace is added in the app.")
        }
        return .project(canonicalPath)
      #endif
    }
    guard Self.isOpenable(canonicalPath, platformPaths: platformPaths) else {
      return .refused(
        "there's no folder at \(canonicalPath). Run `graphcode projects` for the paths "
          + "graphcode knows.")
    }
    return .project(canonicalPath)
  }

  /// Every project this daemon knows about, canonically spelled: what the sidebar has
  /// open, what recents remembers, and whatever is resident.
  private func knownProjectPaths() -> Set<String> {
    var paths = Set(
      persistence.loadOpenProjects().map {
        Self.canonicalize($0, platformPaths: platformPaths)
      })
    paths.formUnion(
      persistence.loadRecentProjects().map {
        Self.canonicalize($0.path, platformPaths: platformPaths)
      })
    paths.formUnion(stores.keys)
    return paths
  }

  /// The deepest known project a path lies inside — deepest so that a nested project a
  /// human deliberately opened wins over the repository around it.
  static func project(containing path: String, in known: Set<String>) -> String? {
    known
      .filter {
        $0 != LoopGraphScope.globalPath
          && (path.hasPrefix($0 + "/") || path.hasPrefix($0 + "\\"))
      }
      .max { $0.count < $1.count }
  }

  // MARK: - The global Orchestrator Graph

  /// Loads the one always-resident global graph
  /// (docs/02-graph-of-loops.md#the-orchestrator-graph--global-vs-project-scope).
  ///
  /// It's just another store keyed by a reserved path, which is what keeps persistence,
  /// broadcasting, and command routing identical to a project's. What makes it global is
  /// where its `.spawn` edges are allowed to point, not a separate code path.
  public func openGlobalGraph(for connectionID: UUID) async {
    guard let channel = connections[connectionID] else { return }
    _ = await open(LoopGraphScope.globalPath, for: connectionID, channel: channel)
  }

  /// Delivers a cross-graph spawn into its target project.
  ///
  /// The target has to already be open. That's a real constraint rather than an
  /// oversight: instantiating into a project nobody has opened would start sessions
  /// against a folder the human isn't looking at, and silently. A dropped spawn is
  /// visible next time they open it; a secret one never is.
  ///
  /// Non-recursive by construction — the global graph spawns into project graphs, and
  /// nothing spawns back. Enforced here rather than trusted: a project graph naming the
  /// global path as its spawn target is refused.
  private func spawnIntoProject(_ targetPath: String, draft: NodeDraft) async {
    let canonicalPath = Self.canonicalize(targetPath, platformPaths: platformPaths)
    guard canonicalPath != LoopGraphScope.globalPath else { return }
    guard let store = stores[canonicalPath] else { return }
    _ = await store.handle(.createNode(draft))
  }

  // MARK: - Store lookup

  private func store(forProjectPath path: String, ensuringSessions: Bool = true) async -> GraphStore
  {
    if let existing = stores[path] { return existing }
    writer.allowWritesAfterDeletion(path: path)
    let persistedGraph = writer.load(path: path)
    let metadata = classifyProject(path)
    let reference = ProjectRef(
      path: path,
      name: Self.displayName(for: path),
      metadata: metadata)
    let loadedGraph = persistedGraph ?? LoopGraph(project: reference)
    let loadedProject = loadedGraph.project
    let authoritativeProject = ProjectRef(
      path: path,
      name: loadedProject.name,
      lastOpenedAt: loadedProject.lastOpenedAt,
      metadata: path == LoopGraphScope.globalPath ? nil : metadata)
    let graph = loadedGraph.enforcingRootProject(authoritativeProject)
    if let persistedGraph, persistedGraph != graph {
      writer.save(graph)
      if persistsSynchronously { writer.flush() }
    }
    let replayStore = self.replayStore
    // A cross-graph spawn arrives here as a plain request; hopping through an unstructured
    // `Task` is what lets this actor re-enter itself to reach a *different* store without
    // deadlocking on its own isolation.
    let spawnIntoProject: @Sendable (String, NodeDraft) -> Void = { [weak self] target, draft in
      Task { await self?.spawnIntoProject(target, draft: draft) }
    }
    let onConnectionFailure: @Sendable (UUID) -> Void = { [weak self] connectionID in
      Task { await self?.removeConnection(connectionID) }
    }
    let trackedEnsureSession: (@Sendable (LoopNode, String?) -> Void)?
    if let launch = ensureSession {
      trackedEnsureSession = { @Sendable [weak self] node, projectPath in
        Task {
          await self?.ensurePreparedSession(node, projectPath: projectPath, launch: launch)
        }
      }
    } else {
      trackedEnsureSession = nil
    }
    let trackedRestartSession: (@Sendable (LoopNode, String?) async -> Bool)?
    if let restart = restartSession {
      trackedRestartSession = { @Sendable [weak self] node, projectPath in
        await self?.restartPreparedSession(
          node, projectPath: projectPath, restart: restart) ?? false
      }
    } else {
      trackedRestartSession = nil
    }
    let newStore = GraphStore(
      graph: graph,
      authoritativeProject: authoritativeProject,
      onGraphChanged: { [weak self, writer, persistsSynchronously] updatedGraph in
        // Handed to the writer and done: this closure runs on the store's actor, and a
        // write of the whole graph held it for as long as the disk took (#307).
        writer.save(updatedGraph)
        if persistsSynchronously { writer.flush() }
        // Every state change is a chance for the last running loop to have stopped, or
        // the first to have started — see `refreshAwakeAssertion`.
        Task { await self?.refreshAwakeAssertion() }
      },
      onDurableGraphChanged: { [weak self, writer] updatedGraph in
        try await writer.saveAcknowledged(updatedGraph)
        await self?.refreshAwakeAssertion()
      },
      onGraphEvent: { event in
        guard case .graphChanged(let updatedGraph) = event else { return [:] }
        return replayStore.append(
          event: event, projectPath: updatedGraph.project.path)
      },
      onConnectionFailure: onConnectionFailure,
      onEnsureSession: trackedEnsureSession,
      onFindMissingProvider: findMissingProvider,
      onTerminateSession: terminateSession,
      onRestartSession: trackedRestartSession,
      onEvaluatePredicate: evaluatePredicate,
      onCheckPredicate: checkPredicate,
      onDeliverMessage: deliverMessage,
      onCaptureScript: captureScript,
      onReadUsage: readUsage,
      onReadActivity: readActivity,
      onReadSummary: readSummary,
      onReadPresence: readPresence,
      onReadGoalVerdict: readGoalVerdict,
      onSessionAlive: sessionAlive,
      onEndSession: CLISessionBackend.endSession,
      onAttachedClients: CLISessionBackend.attachedClients,
      onResumeSession: CLISessionBackend.resumeSession,
      onSpawnIntoProject: spawnIntoProject,
      // The node memory log (`NodeMemory`): episode records in, whole directory out
      // when the node is deleted. Keyed by this store's project path, captured here so
      // `GraphStore` stays unaware of where memory lives — the same split as sessions.
      onAppendMemory: { nodeID, entry in
        NodeMemory.append(entry, projectPath: path, nodeID: nodeID)
      },
      onRemoveMemory: { nodeID in
        NodeMemory.remove(projectPath: path, nodeID: nodeID)
      },
      onRefinePlaybook: { nodeID, text in
        NodeMemory.refinePlaybook(text, projectPath: path, nodeID: nodeID)
      },
      onRollbackPlaybook: { nodeID in
        NodeMemory.rollbackPlaybook(projectPath: path, nodeID: nodeID)
      },
      onHeartbeatEnabled: { GraphcodeSettingsStore.load().daemonHeartbeatEnabled },
      onResolvedSessionGrace: { GraphcodeSettingsStore.load().resolvedSessionGrace },
      onDefaultBackend: { GraphcodeSettingsStore.load().defaultBackend },
      onComposeBoard: composeBoard,
      onBoardsEnabled: {
        let settings = GraphcodeSettingsStore.load()
        // Both, and in this order: a board is drawn from the summary, so the picture is
        // meaningless without the reading that feeds it. Switching the rail off takes the
        // boards with it rather than leaving pictures of a run nothing is narrating.
        return settings.summarisesLoops && settings.visualisesSummaries
      },
      // What a following loop re-reads at its next run: home + this project's
      // `.graphcode/templates`, project winning on a filename collision. See
      // `TemplateStorage`.
      onResolveTemplate: { templateID, projectPath in
        TemplateStorage.shared.template(withID: templateID, projectPath: projectPath)
      },
      // Read fresh per command, the way the heartbeat toggle is: the app resolving
      // the beta ramp (or a hand edit) applies to the next post with no restart.
      onMailroomEnabled: { GraphcodeSettingsStore.load().mailroomEnabled })
    stores[path] = newStore
    // Only on first load of this project — a time-based node's session outlives the app
    // but not a reboot, so something has to restart it, and this is the moment the
    // persisted graph is first seen. Already-running sessions are left untouched.
    if ensuringSessions {
      await newStore.ensureUnattendedSessions()
    }
    // The load-time ensure above is the *local* machine's reboot recovery. A remote host
    // reboots on its own schedule, so its loops need a repeating check as well.
    if ensuringSessions, RemoteProjectLocation.parse(projectPath: path) != nil {
      startRemoteLivenessSweep()
    }
    return newStore
  }

  private func authoritativeRecentProjects() -> [ProjectRef] {
    let stored = persistence.loadRecentProjects()
    let enriched = stored.map { project in
      var copy = project
      copy.metadata = classifyProject(
        Self.canonicalize(project.path, platformPaths: platformPaths))
      return copy
    }
    if enriched != stored { persistence.saveRecentProjects(enriched) }
    return enriched
  }

  /// The global graph's reserved path is a `graphcode://` URL, and a remote project's
  /// is an `ssh://` one — neither is a folder, and running either through
  /// `fileURLWithPath` would mangle it into a relative path under the cwd and route its
  /// commands to a store that doesn't exist.
  /// Whether a path is even the *shape* of a project — checked before `canonicalize`,
  /// which is where the damage was done.
  ///
  /// `URL(fileURLWithPath:)` resolves a relative path against the process's working
  /// directory, and an empty one resolves to that directory outright. `graphcoded` runs
  /// under launchd, whose working directory is `/`, so an empty path arriving from any
  /// client — `graphcode status "$UNSET"` is all it takes — became the root directory,
  /// which exists, so it opened, persisted, and came back every launch as a folder
  /// called "/".
  ///
  /// The root is refused even when spelled out. A project is scanned by the worktree
  /// sweeper and by git; pointed at `/` that is the whole disk.
  static func isWellFormedProjectPath(
    _ path: String,
    platformPaths: any PlatformPaths = CurrentPlatformPaths.value
  ) -> Bool {
    if path == LoopGraphScope.globalPath { return true }
    if RemoteProjectLocation.parse(projectPath: path) != nil { return true }
    return (try? platformPaths.canonicalProjectPath(path)) != nil
  }

  /// Whether a path can be opened as a project right now: well-formed, and a directory
  /// that is actually there.
  ///
  /// The existence half is deliberately not applied when restoring. It is applied here
  /// because this is the door every client knocks on, and without it a mistyped or
  /// already-deleted path became a project with a store, a recents entry and a place in
  /// the restore set — `~/.graphcode/projects` accumulates one JSON per such ghost.
  static func isOpenable(
    _ path: String,
    platformPaths: any PlatformPaths = CurrentPlatformPaths.value
  ) -> Bool {
    guard isWellFormedProjectPath(path, platformPaths: platformPaths) else { return false }
    if path == LoopGraphScope.globalPath { return true }
    if RemoteProjectLocation.parse(projectPath: path) != nil { return true }
    guard let canonicalPath = try? platformPaths.canonicalProjectPath(path) else {
      return false
    }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: canonicalPath, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
  }

  /// The one spelling of a project's path — every store, every persisted entry and every
  /// `.graphChanged` is keyed on it. Public because the app has to key on it too: a
  /// project it asked for by the path a folder picker handed it comes back named by this,
  /// and `/tmp` vs `/private/tmp` is enough to make the two look like different projects.
  public static func canonicalize(
    _ path: String,
    platformPaths: any PlatformPaths = CurrentPlatformPaths.value
  ) -> String {
    guard path != LoopGraphScope.globalPath else { return path }
    // A remote path gets the textual half of the same treatment. It cannot be resolved
    // against this filesystem — the directory is on another machine — but the spellings
    // that fork one project into two are all textual: a trailing slash, a doubled
    // separator, a `.` segment. Left unnormalized, `codespace://cs/workspaces/repo/` and
    // `codespace://cs/workspaces/repo` were two projects, two graphs, and two rows in the
    // sidebar with the same name.
    if let remote = RemoteProjectLocation.parse(projectPath: path) {
      var normalized = remote
      normalized.remotePath = RemoteProjectLocation.normalizedPath(remote.remotePath)
      return normalized.projectPath
    }
    return (try? platformPaths.canonicalProjectPath(path)) ?? path
  }

  private static func displayName(for path: String) -> String {
    if let remote = RemoteProjectLocation.parse(projectPath: path) {
      return remote.displayName
    }
    return URL(fileURLWithPath: path).lastPathComponent
  }

  // MARK: - Unicast reply

  private func send(_ event: DaemonEvent, to connectionID: UUID) async {
    let started = Date()
    guard let data = try? JSONEncoder().encode(event) else { return }
    DaemonLog.shared.record(
      "reply",
      DaemonRequestContext.fields + [
        ("kind", event.kindName), ("connection", connectionID.tag),
        ("bytes", String(data.count)),
        ("encode_ms", DaemonLog.milliseconds(Date().timeIntervalSince(started))),
      ])
    guard let channel = connections[connectionID] else { return }
    do {
      try await channel.sendEvent(event)
    } catch {
      await removeConnection(connectionID)
    }
  }

  private func broadcast(_ event: DaemonEvent) async {
    for id in connections.keys
    where event.requiredCapability.map({
      connectionCapabilities[id]?.contains($0.rawValue) == true
    }) ?? true {
      await send(event, to: id)
    }
  }
}
