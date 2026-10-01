import Foundation
import MailroomKit

public enum GraphPersistenceStage: String, Sendable {
  case beforeGraphWrite
  case afterGraphWrite
  case afterMailroomWrite
  case beforeManifestSwitch
  case afterManifestSwitch
}

public struct GraphPersistenceReceipt: Equatable, Sendable {
  public var projectPath: String
  public var generation: String

  public var identifier: String { "\(generation)|\(projectPath)" }
}

public struct PendingGraphEffects: Sendable {
  public var receipt: GraphPersistenceReceipt
  public var plan: GraphPostCommitEffectPlan
}

/// Reads/writes the on-disk state Phase 4 adds: one JSON file per project's `LoopGraph`
/// plus small recents and open-projects indexes, all under `~/.graphcode` (see
/// `SupportDirectory`) — never inside the project folder itself, so opening a folder in
/// graphcode never touches that folder's own contents (confirmed with the user before
/// building this; see docs/07-roadmap.md#phase-4--projects).
///
/// A plain `Sendable` struct, not an actor: these are small local JSON files and every
/// call site (`ProjectRegistry`) is already actor-isolated, so there's nothing here
/// that needs its own isolation.
public struct ProjectPersistence: Sendable {
  private static let generationLock = NSRecursiveLock()
  private let projectsDirectory: URL
  private let generationsDirectory: URL
  private let recentProjectsFile: URL
  private let openProjectsFile: URL
  private let platformPaths: any PlatformPaths
  private let beforeGraphWrite: @Sendable (LoopGraph) throws -> Void
  private let beforeGraphDelete: @Sendable (String) throws -> Void
  private let beforeGraphTransactionStage:
    @Sendable (LoopGraph, GraphPersistenceStage) throws -> Void

  public init(baseDirectory: URL) {
    self.init(baseDirectory: baseDirectory, platformPaths: CurrentPlatformPaths.value)
  }

  public init(
    baseDirectory: URL,
    platformPaths: any PlatformPaths,
    beforeGraphWrite: @escaping @Sendable (LoopGraph) throws -> Void = { _ in },
    beforeGraphDelete: @escaping @Sendable (String) throws -> Void = { _ in },
    beforeGraphTransactionStage:
      @escaping @Sendable (LoopGraph, GraphPersistenceStage) throws ->
      Void = { _, _ in }
  ) {
    projectsDirectory = baseDirectory.appendingPathComponent("projects", isDirectory: true)
    generationsDirectory = projectsDirectory.appendingPathComponent(
      ".generations", isDirectory: true)
    recentProjectsFile = baseDirectory.appendingPathComponent("recent-projects.json")
    openProjectsFile = baseDirectory.appendingPathComponent("open-projects.json")
    self.platformPaths = platformPaths
    self.beforeGraphWrite = beforeGraphWrite
    self.beforeGraphDelete = beforeGraphDelete
    self.beforeGraphTransactionStage = beforeGraphTransactionStage
    try? FileManager.default.createDirectory(
      at: projectsDirectory, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(
      at: generationsDirectory, withIntermediateDirectories: true)
  }

  private struct GenerationManifest: Codable {
    var version: Int
    var generation: String
    var deleted: Bool?
  }

  private struct DurableEffectEnvelope: Codable {
    var version: Int
    var projectPath: String
    var plan: GraphPostCommitEffectPlan
  }

  // MARK: - Per-project graph

  public func loadGraph(path: String) -> LoopGraph? {
    if let manifest = loadManifest(path: path) {
      return loadGeneration(path: path, manifest: manifest)
    }
    let currentURL = fileURL(forProjectPath: path)
    if let graph = decodeGraph(at: currentURL, projectPath: path) {
      do {
        _ = try saveGraphAcknowledged(graph)
      } catch {
        recordCompatibilityPersistenceFailure("graph-migration-save-failure", error: error)
      }
      return graph
    }

    // Before v1 keys, macOS used the path itself as the filename. Keep this fallback
    // one-way: a successful read immediately moves the bytes to the safe filename so
    // future launches no longer depend on the legacy spelling.
    let legacyURL = legacyFileURL(forProjectPath: path)
    guard let legacyData = try? Data(contentsOf: legacyURL),
      let legacyGraph = try? JSONDecoder().decode(LoopGraph.self, from: legacyData),
      pathsMatch(legacyGraph.project.path, path)
    else { return nil }
    if (try? legacyData.write(to: currentURL, options: .atomic)) != nil {
      try? FileManager.default.removeItem(at: legacyURL)
      migrateLegacyMailroom(forProjectPath: path)
    }
    return decodeGraph(data: legacyData, projectPath: path)
  }

  private func loadGeneration(path: String) -> LoopGraph? {
    guard let manifest = loadManifest(path: path) else { return nil }
    return loadGeneration(path: path, manifest: manifest)
  }

  private func loadGeneration(path: String, manifest: GenerationManifest) -> LoopGraph? {
    guard manifest.deleted != true else { return nil }
    let graphURL = generationGraphURL(path: path, generation: manifest.generation)
    let roomURL = generationMailroomURL(path: path, generation: manifest.generation)
    guard let graphData = try? SafeLocalFile.read(graphURL, maximumBytes: 64 * 1_024 * 1_024),
      let roomData = try? SafeLocalFile.read(roomURL, maximumBytes: 64 * 1_024 * 1_024),
      var graph = try? JSONDecoder().decode(LoopGraph.self, from: graphData),
      pathsMatch(graph.project.path, path),
      let room = try? JSONDecoder().decode([MailroomPost].self, from: roomData)
    else { return nil }
    graph.mailroom = room
    for index in graph.nodes.indices {
      graph.nodes[index].presence = nil
      graph.nodes[index].activity = nil
    }
    return graph
  }

  private func loadManifest(path: String) -> GenerationManifest? {
    let url = manifestURL(forProjectPath: path)
    guard let data = try? SafeLocalFile.read(url, maximumBytes: 4_096),
      let manifest = try? JSONDecoder().decode(GenerationManifest.self, from: data),
      manifest.version == 1, UUID(uuidString: manifest.generation) != nil
    else { return nil }
    return manifest
  }

  private func decodeGraph(at url: URL, projectPath: String) -> LoopGraph? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return decodeGraph(data: data, projectPath: projectPath)
  }

  private func decodeGraph(data: Data, projectPath: String) -> LoopGraph? {
    guard var graph = try? JSONDecoder().decode(LoopGraph.self, from: data) else { return nil }
    for index in graph.nodes.indices {
      graph.nodes[index].presence = nil
      graph.nodes[index].activity = nil
    }
    // The room's own file wins over one still inline in the graph file — a graph saved
    // before the split carries its posts inline, and decodes exactly as it always did.
    let currentRoom = mailroomURL(forProjectPath: projectPath)
    let legacyRoom = legacyMailroomURL(forProjectPath: projectPath)
    if let room = (try? Data(contentsOf: currentRoom)) ?? (try? Data(contentsOf: legacyRoom)),
      let posts = try? JSONDecoder().decode([MailroomPost].self, from: room)
    {
      graph.mailroom = posts
    }
    return graph
  }

  /// Two files: the graph without its room, rewritten on every change, and the room on
  /// its own, rewritten only when the room changed. The room was 84% of the graph file
  /// (271 KB of 323 KB on the graph that filed #307) and changes only when a post lands,
  /// while the graph changes on every memo, state tick and cursor move — the same
  /// argument #293 made for the wire, applied to the file.
  public func saveGraph(_ graph: LoopGraph) {
    do {
      _ = try saveGraphAcknowledged(graph)
    } catch {
      recordCompatibilityPersistenceFailure("graph-save-failure", error: error)
    }
  }

  /// Saves the complete restorable graph and returns only after the graph file has been
  /// atomically replaced. Unlike the compatibility `saveGraph` entry point, failures
  /// are surfaced to callers that must not publish or perform irreversible follow-up
  /// work until persistence is known to have succeeded.
  @discardableResult
  public func saveGraphAcknowledged(
    _ graph: LoopGraph,
    effectPlan: GraphPostCommitEffectPlan? = nil
  ) throws -> GraphPersistenceReceipt {
    try Self.withGenerationLock {
      try saveGraphTransaction(graph, effectPlan: effectPlan)
    }
  }

  private func saveGraphTransaction(
    _ graph: LoopGraph,
    effectPlan: GraphPostCommitEffectPlan?
  ) throws -> GraphPersistenceReceipt {
    var slim = graph
    slim.mailroom = []
    let graphData = try JSONEncoder().encode(slim)
    let roomData = try JSONEncoder().encode(graph.mailroom)
    let generation = UUID().uuidString
    let directory = generationDirectory(forProjectPath: graph.project.path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let graphURL = generationGraphURL(path: graph.project.path, generation: generation)
    let roomURL = generationMailroomURL(path: graph.project.path, generation: generation)
    let effectsURL = generationEffectsURL(path: graph.project.path, generation: generation)
    var manifestSwitched = false
    do {
      try beforeGraphTransactionStage(graph, .beforeGraphWrite)
      try beforeGraphWrite(graph)
      try graphData.write(to: graphURL, options: .atomic)
      try beforeGraphTransactionStage(graph, .afterGraphWrite)
      try roomData.write(to: roomURL, options: .atomic)
      try beforeGraphTransactionStage(graph, .afterMailroomWrite)
      if let effectPlan, !effectPlan.operations.isEmpty {
        let envelope = DurableEffectEnvelope(
          version: 1, projectPath: graph.project.path, plan: effectPlan)
        try JSONEncoder().encode(envelope).write(to: effectsURL, options: .atomic)
      }
      try beforeGraphTransactionStage(graph, .beforeManifestSwitch)
      let manifest = GenerationManifest(version: 1, generation: generation, deleted: false)
      try JSONEncoder().encode(manifest).write(
        to: manifestURL(forProjectPath: graph.project.path), options: .atomic)
      manifestSwitched = true
    } catch {
      if !manifestSwitched {
        for url in [graphURL, roomURL, effectsURL]
        where FileManager.default.fileExists(atPath: url.path) {
          try? FileManager.default.removeItem(at: url)
        }
      }
      throw error
    }
    do {
      try beforeGraphTransactionStage(graph, .afterManifestSwitch)
    } catch {
      DaemonLog.shared.record(
        "graph-persistence-post-commit-failure",
        [
          ("project", platformPaths.persistenceKey(forProjectPath: graph.project.path)),
          ("error", String(describing: error)),
        ])
    }
    removeLegacyGraphIfMatching(path: graph.project.path)
    for url in [
      fileURL(forProjectPath: graph.project.path),
      mailroomURL(forProjectPath: graph.project.path),
      legacyMailroomURL(forProjectPath: graph.project.path),
    ] where FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }
    pruneAppliedGenerations(path: graph.project.path, keeping: generation)
    return GraphPersistenceReceipt(projectPath: graph.project.path, generation: generation)
  }

  /// Deletes the authoritative graph first. Only failures before that unlink are
  /// surfaced; stale sidecars are non-authoritative and are removed best-effort after
  /// the graph is gone. Therefore every thrown error leaves the complete graph
  /// restorable, while every success makes deletion authoritative.
  @discardableResult
  public func deleteGraphAcknowledged(
    path: String,
    effectPlan: GraphPostCommitEffectPlan? = nil
  ) throws -> GraphPersistenceReceipt {
    try Self.withGenerationLock {
      try deleteGraphTransaction(path: path, effectPlan: effectPlan)
    }
  }

  private func deleteGraphTransaction(
    path: String,
    effectPlan: GraphPostCommitEffectPlan?
  ) throws -> GraphPersistenceReceipt {
    let generation = UUID().uuidString
    let receipt = GraphPersistenceReceipt(projectPath: path, generation: generation)
    let effectsURL = generationEffectsURL(path: path, generation: generation)
    let directory = generationDirectory(forProjectPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let hasEffects = effectPlan?.operations.isEmpty == false
    if let effectPlan, hasEffects {
      let envelope = DurableEffectEnvelope(version: 1, projectPath: path, plan: effectPlan)
      try JSONEncoder().encode(envelope).write(to: effectsURL, options: .atomic)
    }
    do {
      try beforeGraphDelete(path)
      let manifest = GenerationManifest(version: 1, generation: generation, deleted: true)
      try JSONEncoder().encode(manifest).write(
        to: manifestURL(forProjectPath: path), options: .atomic)
    } catch {
      try? FileManager.default.removeItem(at: effectsURL)
      throw error
    }
    removeLegacyAuthoritativeGraph(path: path)
    if !hasEffects {
      try? FileManager.default.removeItem(at: manifestURL(forProjectPath: path))
      pruneAppliedGenerations(path: path, keeping: nil)
    }
    return receipt
  }

  private func removeLegacyAuthoritativeGraph(path: String) {
    for url in [
      fileURL(forProjectPath: path),
      mailroomURL(forProjectPath: path),
      legacyFileURL(forProjectPath: path),
      legacyMailroomURL(forProjectPath: path),
    ] where FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }
    Self.roomDigests.forget(mailroomURL(forProjectPath: path).path)
  }

  public func loadStoredGraphs() -> [LoopGraph] {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: projectsDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles])
    else { return [] }
    var graphs: [String: LoopGraph] = [:]
    for url in files where url.lastPathComponent.hasSuffix(Self.manifestFileSuffix) {
      let name = url.lastPathComponent
      let key = String(name.dropLast(Self.manifestFileSuffix.count))
      guard let path = projectPathFromGenerationDirectory(key: key),
        let graph = loadGeneration(path: path)
      else { continue }
      graphs[graph.project.path] = graph
    }
    for url in files {
      guard url.pathExtension == "json", !Self.isSidecarFileName(url.lastPathComponent),
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true, values.isSymbolicLink != true,
        let data = try? SafeLocalFile.read(url, maximumBytes: 64 * 1_024 * 1_024),
        let graph = try? JSONDecoder().decode(LoopGraph.self, from: data)
      else { continue }
      if graphs[graph.project.path] == nil {
        graphs[graph.project.path] = decodeGraph(data: data, projectPath: graph.project.path)
      }
    }
    return Array(graphs.values)
  }

  public func loadPendingGraphEffects() -> [PendingGraphEffects] {
    Self.withGenerationLock {
      loadPendingGraphEffectsLocked()
    }
  }

  private func loadPendingGraphEffectsLocked() -> [PendingGraphEffects] {
    guard
      let projectDirectories = try? FileManager.default.contentsOfDirectory(
        at: generationsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { return [] }
    var pending: [PendingGraphEffects] = []
    for directory in projectDirectories {
      guard
        (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
        let files = try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      else { continue }
      for effectsURL in files where effectsURL.lastPathComponent.hasSuffix(".effects.json") {
        let generation = String(effectsURL.lastPathComponent.dropLast(".effects.json".count))
        guard UUID(uuidString: generation) != nil,
          !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(generation).effects-applied").path),
          let data = try? SafeLocalFile.read(effectsURL, maximumBytes: 8 * 1_024 * 1_024),
          let envelope = try? JSONDecoder().decode(DurableEffectEnvelope.self, from: data),
          envelope.version == 1, envelope.plan.projectPath == envelope.projectPath,
          loadManifest(path: envelope.projectPath)?.generation == generation
        else { continue }
        pending.append(
          PendingGraphEffects(
            receipt: GraphPersistenceReceipt(
              projectPath: envelope.projectPath, generation: generation),
            plan: envelope.plan))
      }
    }
    return pending
  }

  public func markGraphEffectsApplied(_ receipt: GraphPersistenceReceipt) {
    Self.withGenerationLock {
      markGraphEffectsAppliedLocked(receipt)
    }
  }

  private func markGraphEffectsAppliedLocked(_ receipt: GraphPersistenceReceipt) {
    let marker = generationEffectsAppliedURL(
      path: receipt.projectPath, generation: receipt.generation)
    do {
      try Data().write(to: marker, options: .atomic)
      let manifest = loadManifest(path: receipt.projectPath)
      if manifest?.generation == receipt.generation, manifest?.deleted == true {
        try? FileManager.default.removeItem(at: manifestURL(forProjectPath: receipt.projectPath))
        pruneAppliedGenerations(path: receipt.projectPath, keeping: nil)
      } else {
        pruneAppliedGenerations(
          path: receipt.projectPath,
          keeping: manifest?.generation)
      }
    } catch {
      DaemonLog.shared.record(
        "graph-effects-ack-failure",
        [
          ("project", platformPaths.persistenceKey(forProjectPath: receipt.projectPath)),
          ("generation", receipt.generation),
        ])
    }
  }

  /// Throws away a project's loops for good — the "Delete Loops…" half of the sidebar's
  /// context menu, which is why it's separate from `forgetProject`. Only ever touches
  /// graphcode's own file under `~/.graphcode`; the project folder itself is never
  /// written to, deleted from, or otherwise modified.
  public func deleteGraph(path: String) {
    do {
      _ = try deleteGraphAcknowledged(path: path)
    } catch {
      recordCompatibilityPersistenceFailure("graph-delete-failure", error: error)
    }
  }

  /// What the room last written for each project looked like, so an unchanged room is
  /// not rewritten. Process-wide because this type is a value: every copy writes the
  /// same files. A miss (first save after launch) writes once and is then remembered.
  ///
  /// Keyed by the room *file*, not the project path: one path is the same project in
  /// every workspace but a different file in each, and sharing an entry across them
  /// would judge a room unchanged against a digest taken from someone else's file and
  /// never write it.
  private static let roomDigests = RoomDigests()

  private final class RoomDigests: @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [String: MailroomDigest] = [:]

    func matches(_ digest: MailroomDigest, for path: String) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return digests[path] == digest
    }

    func set(_ digest: MailroomDigest, for path: String) {
      lock.lock()
      digests[path] = digest
      lock.unlock()
    }

    func forget(_ path: String) {
      lock.lock()
      defer { lock.unlock() }
      digests.removeValue(forKey: path)
    }
  }

  /// Filenames are versioned hashes of the canonical project path. A path-derived filename
  /// must be deterministic across launches, but Windows also rejects `:`, `\`, and several
  /// other characters that occur in perfectly valid project paths. Hashing keeps names
  /// short, safe, and collision-resistant without leaking a path into a directory listing.
  private func fileURL(forProjectPath path: String) -> URL {
    let key = platformPaths.persistenceKey(forProjectPath: path)
    return projectsDirectory.appendingPathComponent("\(key).json")
  }

  private func manifestURL(forProjectPath path: String) -> URL {
    let key = platformPaths.persistenceKey(forProjectPath: path)
    return projectsDirectory.appendingPathComponent("\(key)\(Self.manifestFileSuffix)")
  }

  private func generationDirectory(forProjectPath path: String) -> URL {
    generationsDirectory.appendingPathComponent(
      platformPaths.persistenceKey(forProjectPath: path), isDirectory: true)
  }

  private func generationGraphURL(path: String, generation: String) -> URL {
    generationDirectory(forProjectPath: path)
      .appendingPathComponent("\(generation).graph.json")
  }

  private func generationMailroomURL(path: String, generation: String) -> URL {
    generationDirectory(forProjectPath: path)
      .appendingPathComponent("\(generation).mailroom.json")
  }

  private func generationEffectsURL(path: String, generation: String) -> URL {
    generationDirectory(forProjectPath: path)
      .appendingPathComponent("\(generation).effects.json")
  }

  private func generationEffectsAppliedURL(path: String, generation: String) -> URL {
    generationDirectory(forProjectPath: path)
      .appendingPathComponent("\(generation).effects-applied")
  }

  private func projectPathFromGenerationDirectory(key: String) -> String? {
    let manifestURL = projectsDirectory.appendingPathComponent("\(key)\(Self.manifestFileSuffix)")
    guard let data = try? SafeLocalFile.read(manifestURL, maximumBytes: 4_096),
      let manifest = try? JSONDecoder().decode(GenerationManifest.self, from: data),
      manifest.version == 1, UUID(uuidString: manifest.generation) != nil
    else { return nil }
    let graphURL =
      generationsDirectory.appendingPathComponent(key, isDirectory: true)
      .appendingPathComponent("\(manifest.generation).graph.json")
    guard let graphData = try? SafeLocalFile.read(graphURL, maximumBytes: 64 * 1_024 * 1_024),
      let graph = try? JSONDecoder().decode(LoopGraph.self, from: graphData),
      platformPaths.persistenceKey(forProjectPath: graph.project.path) == key
    else { return nil }
    return graph.project.path
  }

  private func pruneAppliedGenerations(path: String, keeping generation: String?) {
    let directory = generationDirectory(forProjectPath: path)
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    let generations = Set(
      files.compactMap { url -> String? in
        let name = url.lastPathComponent
        guard let separator = name.firstIndex(of: ".") else { return nil }
        let value = String(name[..<separator])
        return UUID(uuidString: value) == nil ? nil : value
      })
    for old in generations where old != generation {
      let effects = generationEffectsURL(path: path, generation: old)
      let applied = generationEffectsAppliedURL(path: path, generation: old)
      guard
        !FileManager.default.fileExists(atPath: effects.path)
          || FileManager.default.fileExists(atPath: applied.path)
      else { continue }
      for url in files where url.lastPathComponent.hasPrefix("\(old).") {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  private func legacyFileURL(forProjectPath path: String) -> URL {
    let safeName = path.replacingOccurrences(of: "/", with: "_")
    return projectsDirectory.appendingPathComponent("\(safeName).json")
  }

  /// The room beside its graph: `<name>.mailroom.json`.
  private func mailroomURL(forProjectPath path: String) -> URL {
    let key = platformPaths.persistenceKey(forProjectPath: path)
    return projectsDirectory.appendingPathComponent("\(key)\(Self.roomFileSuffix)")
  }

  private func legacyMailroomURL(forProjectPath path: String) -> URL {
    let safeName = path.replacingOccurrences(of: "/", with: "_")
    return projectsDirectory.appendingPathComponent("\(safeName)\(Self.roomFileSuffix)")
  }

  /// Every suffix this type writes into `projects/` *beside* a graph rather than as one.
  ///
  /// `projects/` held nothing but graphs until #307 moved the room out of the graph file,
  /// so readers scanning it — `OrphanedSessionReaper`, `Workspace.contents` — took every
  /// `.json` in it for a graph. That assumption is now false, and it failed loudly in the
  /// worst place: `reap` treats an undecodable file as state it cannot account for and
  /// aborts, so a room file disabled the tool people reach for when they are out of PTYs.
  ///
  /// **Adding a sidecar means adding its suffix here**, in the same type that mints the
  /// name, so a reader never has to be taught about it separately. Anything not listed
  /// still fails closed, which is the safe direction but also a silently broken `reap`.
  static let roomFileSuffix = ".mailroom.json"
  static let manifestFileSuffix = ".current.json"
  static let sidecarFileSuffixes = [roomFileSuffix, manifestFileSuffix]

  /// Whether a file in `projects/` is a sidecar rather than a graph. Answered from the
  /// name alone and deliberately not from the contents: a *corrupt* sidecar is still a
  /// sidecar, and it never owned a session, so it must not be mistaken for a damaged
  /// graph and stop a reap.
  public static func isSidecarFileName(_ name: String) -> Bool {
    sidecarFileSuffixes.contains { name.hasSuffix($0) }
  }

  private func removeLegacyGraphIfMatching(path: String) {
    let legacyURL = legacyFileURL(forProjectPath: path)
    guard let data = try? Data(contentsOf: legacyURL),
      let graph = try? JSONDecoder().decode(LoopGraph.self, from: data),
      pathsMatch(graph.project.path, path)
    else { return }
    try? FileManager.default.removeItem(at: legacyURL)
    migrateLegacyMailroom(forProjectPath: path)
  }

  private func migrateLegacyMailroom(forProjectPath path: String) {
    let legacyURL = legacyMailroomURL(forProjectPath: path)
    let currentURL = mailroomURL(forProjectPath: path)
    guard !FileManager.default.fileExists(atPath: currentURL.path),
      let data = try? Data(contentsOf: legacyURL),
      (try? data.write(to: currentURL, options: .atomic)) != nil
    else { return }
    try? FileManager.default.removeItem(at: legacyURL)
  }

  private func pathsMatch(_ storedPath: String, _ requestedPath: String) -> Bool {
    if storedPath == requestedPath { return true }
    guard let storedCanonical = try? platformPaths.canonicalProjectPath(storedPath),
      let requestedCanonical = try? platformPaths.canonicalProjectPath(requestedPath)
    else { return false }
    return storedCanonical == requestedCanonical
  }

  // MARK: - Recent projects

  public func loadRecentProjects() -> [ProjectRef] {
    guard let data = try? Data(contentsOf: recentProjectsFile) else { return [] }
    let projects = (try? JSONDecoder().decode([ProjectRef].self, from: data)) ?? []
    return projects.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
  }

  public func recordOpened(_ project: ProjectRef) {
    var projects = loadRecentProjects().filter { $0.path != project.path }
    projects.append(project)
    saveRecentProjects(projects)
  }

  /// Drops a project from the recents index — "Remove from Graphcode". Its saved graph
  /// stays on disk, so re-opening the same folder brings the loops back; wiping those is
  /// `deleteGraph(path:)`, a deliberately separate and separately-confirmed action.
  public func forgetProject(path: String) {
    saveRecentProjects(loadRecentProjects().filter { $0.path != path })
  }

  func saveRecentProjects(_ projects: [ProjectRef]) {
    guard let data = try? JSONEncoder().encode(projects) else { return }
    try? data.write(to: recentProjectsFile, options: .atomic)
  }

  // MARK: - Open projects

  /// Which projects the sidebar was showing, as distinct from which have ever been
  /// opened. Keeping these separate is what lets "Close" and "Remove from Graphcode" mean
  /// different things: closing a project drops it from here but leaves it in recents, so
  /// it stays one click away under Add Folder.
  public func loadOpenProjects() -> [String] {
    guard let data = try? Data(contentsOf: openProjectsFile) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
  }

  public func saveOpenProjects(_ paths: [String]) {
    guard let data = try? JSONEncoder().encode(paths) else { return }
    try? data.write(to: openProjectsFile, options: .atomic)
  }

  public func completeProjectRelocation(
    from sourcePath: String,
    to destinationPath: String,
    graph: LoopGraph,
    supportSourcePath: String? = nil
  ) throws {
    var rewritten = graph
    let project = ProjectRef(
      path: destinationPath,
      name: URL(fileURLWithPath: destinationPath).lastPathComponent,
      lastOpenedAt: graph.project.lastOpenedAt,
      metadata: graph.project.metadata)
    rewritten = rewritten.enforcingRootProject(project)

    _ = try saveGraphAcknowledged(rewritten)

    try NodeMemory.relocateProjectStorage(
      from: supportSourcePath ?? sourcePath, to: destinationPath,
      baseURL: projectsDirectory.deletingLastPathComponent())

    let recents = loadRecentProjects().map { recent in
      guard relocationPathsMatch(recent.path, sourcePath) else { return recent }
      return ProjectRef(
        path: destinationPath,
        name: project.name,
        lastOpenedAt: recent.lastOpenedAt,
        metadata: project.metadata)
    }
    try JSONEncoder().encode(recents).write(to: recentProjectsFile, options: .atomic)
    let open = loadOpenProjects().map {
      relocationPathsMatch($0, sourcePath) ? destinationPath : $0
    }
    try JSONEncoder().encode(open).write(to: openProjectsFile, options: .atomic)
    try LoopHistoryStore(baseDirectory: projectsDirectory.deletingLastPathComponent())
      .relocateProject(from: sourcePath, to: destinationPath)

    for url in [
      manifestURL(forProjectPath: sourcePath),
      fileURL(forProjectPath: sourcePath),
      mailroomURL(forProjectPath: sourcePath),
      legacyFileURL(forProjectPath: sourcePath),
      legacyMailroomURL(forProjectPath: sourcePath),
    ] where FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    Self.roomDigests.forget(mailroomURL(forProjectPath: sourcePath).path)
  }

  public func preflightProjectRelocationDestination(_ destinationPath: String) throws {
    let files = [
      manifestURL(forProjectPath: destinationPath),
      generationDirectory(forProjectPath: destinationPath),
      fileURL(forProjectPath: destinationPath),
      mailroomURL(forProjectPath: destinationPath),
      legacyFileURL(forProjectPath: destinationPath),
      legacyMailroomURL(forProjectPath: destinationPath),
    ]
    guard !files.contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
      !loadRecentProjects().contains(where: {
        relocationPathsMatch($0.path, destinationPath)
      }),
      !loadOpenProjects().contains(where: {
        relocationPathsMatch($0, destinationPath)
      }),
      !NodeMemory.hasProjectStorage(
        projectPath: destinationPath,
        baseURL: projectsDirectory.deletingLastPathComponent()),
      !LoopHistoryStore(baseDirectory: projectsDirectory.deletingLastPathComponent())
        .containsProjectPath(destinationPath)
    else {
      throw ProjectRelocationError.destinationCollision
    }
  }

  private func relocationPathsMatch(_ lhs: String, _ rhs: String) -> Bool {
    #if os(Windows)
      return lhs.replacingOccurrences(of: "\\", with: "/").lowercased()
        == rhs.replacingOccurrences(of: "\\", with: "/").lowercased()
    #else
      return lhs == rhs
    #endif
  }

  private static func withGenerationLock<T>(_ operation: () throws -> T) rethrows -> T {
    generationLock.lock()
    defer { generationLock.unlock() }
    return try operation()
  }

  private func recordCompatibilityPersistenceFailure(_ event: String, error: any Error) {
    DaemonLog.shared.record(
      event,
      [
        ("error-type", String(reflecting: type(of: error)))
      ])
  }
}
