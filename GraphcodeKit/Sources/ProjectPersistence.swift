import Foundation
import MailroomKit

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
  private let projectsDirectory: URL
  private let recentProjectsFile: URL
  private let openProjectsFile: URL
  private let platformPaths: any PlatformPaths
  private let beforeGraphWrite: @Sendable (LoopGraph) throws -> Void
  private let beforeGraphDelete: @Sendable (String) throws -> Void

  public init(baseDirectory: URL) {
    self.init(baseDirectory: baseDirectory, platformPaths: CurrentPlatformPaths.value)
  }

  public init(
    baseDirectory: URL,
    platformPaths: any PlatformPaths,
    beforeGraphWrite: @escaping @Sendable (LoopGraph) throws -> Void = { _ in },
    beforeGraphDelete: @escaping @Sendable (String) throws -> Void = { _ in }
  ) {
    projectsDirectory = baseDirectory.appendingPathComponent("projects", isDirectory: true)
    recentProjectsFile = baseDirectory.appendingPathComponent("recent-projects.json")
    openProjectsFile = baseDirectory.appendingPathComponent("open-projects.json")
    self.platformPaths = platformPaths
    self.beforeGraphWrite = beforeGraphWrite
    self.beforeGraphDelete = beforeGraphDelete
    try? FileManager.default.createDirectory(
      at: projectsDirectory, withIntermediateDirectories: true)
  }

  // MARK: - Per-project graph

  public func loadGraph(path: String) -> LoopGraph? {
    let currentURL = fileURL(forProjectPath: path)
    if let graph = decodeGraph(at: currentURL, projectPath: path) {
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
    try? saveGraphAcknowledged(graph)
  }

  /// Saves the complete restorable graph and returns only after the graph file has been
  /// atomically replaced. Unlike the compatibility `saveGraph` entry point, failures
  /// are surfaced to callers that must not publish or perform irreversible follow-up
  /// work until persistence is known to have succeeded.
  public func saveGraphAcknowledged(_ graph: LoopGraph) throws {
    var slim = graph
    slim.mailroom = []
    let data = try JSONEncoder().encode(slim)
    let roomURL = mailroomURL(forProjectPath: graph.project.path)
    let digest = MailroomDigest(of: graph.mailroom)
    if !Self.roomDigests.matches(digest, for: roomURL.path)
      || !FileManager.default.fileExists(atPath: roomURL.path)
    {
      if graph.mailroom.isEmpty {
        if FileManager.default.fileExists(atPath: roomURL.path) {
          try FileManager.default.removeItem(at: roomURL)
        }
      } else {
        try JSONEncoder().encode(graph.mailroom).write(to: roomURL, options: .atomic)
      }
      Self.roomDigests.set(digest, for: roomURL.path)
    }
    try beforeGraphWrite(graph)
    try data.write(to: fileURL(forProjectPath: graph.project.path), options: .atomic)
    removeLegacyGraphIfMatching(path: graph.project.path)
    if FileManager.default.fileExists(
      atPath: legacyMailroomURL(forProjectPath: graph.project.path)
        .path)
    {
      do {
        try FileManager.default.removeItem(
          at: legacyMailroomURL(forProjectPath: graph.project.path))
      } catch {
        // The current graph and room are already durable. A stale compatibility file
        // cannot override them and is safe to remove on a later save.
      }
    }
  }

  /// Deletes the authoritative graph first. Only failures before that unlink are
  /// surfaced; stale sidecars are non-authoritative and are removed best-effort after
  /// the graph is gone. Therefore every thrown error leaves the complete graph
  /// restorable, while every success makes deletion authoritative.
  public func deleteGraphAcknowledged(path: String) throws {
    try beforeGraphDelete(path)
    let graphURL = fileURL(forProjectPath: path)
    if FileManager.default.fileExists(atPath: graphURL.path) {
      try FileManager.default.removeItem(at: graphURL)
    }
    for url in [
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
    return files.compactMap { url in
      guard url.pathExtension == "json", !Self.isSidecarFileName(url.lastPathComponent),
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true, values.isSymbolicLink != true,
        let data = try? SafeLocalFile.read(url, maximumBytes: 64 * 1_024 * 1_024),
        let graph = try? JSONDecoder().decode(LoopGraph.self, from: data)
      else { return nil }
      return decodeGraph(data: data, projectPath: graph.project.path)
    }
  }

  /// Throws away a project's loops for good — the "Delete Loops…" half of the sidebar's
  /// context menu, which is why it's separate from `forgetProject`. Only ever touches
  /// graphcode's own file under `~/.graphcode`; the project folder itself is never
  /// written to, deleted from, or otherwise modified.
  public func deleteGraph(path: String) {
    try? deleteGraphAcknowledged(path: path)
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
  static let sidecarFileSuffixes = [roomFileSuffix]

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

    var slim = rewritten
    slim.mailroom = []
    try JSONEncoder().encode(slim).write(
      to: fileURL(forProjectPath: destinationPath), options: .atomic)
    let destinationRoom = mailroomURL(forProjectPath: destinationPath)
    if rewritten.mailroom.isEmpty {
      if FileManager.default.fileExists(atPath: destinationRoom.path) {
        try FileManager.default.removeItem(at: destinationRoom)
      }

    } else {
      try JSONEncoder().encode(rewritten.mailroom).write(to: destinationRoom, options: .atomic)
    }

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
}
