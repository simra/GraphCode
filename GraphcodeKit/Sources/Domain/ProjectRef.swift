import Foundation

public enum ProjectLocationKind: String, Codable, Equatable, Sendable {
  case local
  case ssh
  case codespace
}

public struct ProjectCapabilities: Codable, Equatable, Sendable {
  public var revealInFileManager: Bool
  public var templates: Bool
  public var attachments: Bool
  public var interactiveTerminals: Bool
  public var diagnostics: Bool

  public init(
    revealInFileManager: Bool = false,
    templates: Bool = false,
    attachments: Bool = false,
    interactiveTerminals: Bool = false,
    diagnostics: Bool = false
  ) {
    self.revealInFileManager = revealInFileManager
    self.templates = templates
    self.attachments = attachments
    self.interactiveTerminals = interactiveTerminals
    self.diagnostics = diagnostics
  }

  private enum CodingKeys: String, CodingKey {
    case revealInFileManager, templates, attachments, interactiveTerminals, diagnostics
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    revealInFileManager =
      try container.decodeIfPresent(Bool.self, forKey: .revealInFileManager) ?? false
    templates = try container.decodeIfPresent(Bool.self, forKey: .templates) ?? false
    attachments = try container.decodeIfPresent(Bool.self, forKey: .attachments) ?? false
    interactiveTerminals =
      try container.decodeIfPresent(Bool.self, forKey: .interactiveTerminals) ?? false
    diagnostics = try container.decodeIfPresent(Bool.self, forKey: .diagnostics) ?? false
  }
}

public struct ProjectMetadata: Codable, Equatable, Sendable {
  public var location: ProjectLocationKind
  public var capabilities: ProjectCapabilities

  public init(location: ProjectLocationKind, capabilities: ProjectCapabilities) {
    self.location = location
    self.capabilities = capabilities
  }

  private enum CodingKeys: String, CodingKey {
    case location, capabilities
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    location = try container.decode(ProjectLocationKind.self, forKey: .location)
    capabilities =
      try container.decodeIfPresent(ProjectCapabilities.self, forKey: .capabilities)
      ?? ProjectCapabilities()
  }

  public static let local = ProjectMetadata(
    location: .local,
    capabilities: ProjectCapabilities(
      revealInFileManager: true,
      templates: true,
      attachments: true,
      interactiveTerminals: true,
      diagnostics: true))

  public static let ssh = ProjectMetadata(
    location: .ssh,
    capabilities: ProjectCapabilities(diagnostics: true))

  public static let codespace = ProjectMetadata(
    location: .codespace,
    capabilities: ProjectCapabilities(diagnostics: true))

  public static func inferred(fromProjectPath path: String) -> ProjectMetadata {
    guard let remote = RemoteProjectLocation.parse(projectPath: path) else { return .local }
    return remote.isCodespace ? .codespace : .ssh
  }
}

/// A folder (or repository) graphcode has opened as a project — see
/// docs/02-graph-of-loops.md#loopgraph. `path` is the canonicalized absolute
/// filesystem path and is the stable identity: it's what a `LoopGraph`'s persisted
/// file on disk is keyed by, and what the welcome screen's recent-projects list
/// de-duplicates on.
///
/// This is the first concrete piece of the `LoopGraphScope.project(ProjectRef)` the
/// docs have described since Phase 2 — there is still no `.global` Orchestrator Graph
/// and no `LoopGraphScope` enum, since every graph today is implicitly project-scoped
/// (see `LoopGraph`'s doc comment).
public struct ProjectRef: Identifiable, Codable, Equatable, Sendable {
  public var path: String
  public var name: String
  public var lastOpenedAt: Date
  /// Daemon-owned classification and currently implemented project operations. Optional
  /// so persisted references and clients from before this field continue to decode.
  public var metadata: ProjectMetadata?

  public var id: String { path }

  private enum CodingKeys: String, CodingKey {
    case path, name, lastOpenedAt, metadata
  }

  public init(
    path: String,
    name: String,
    lastOpenedAt: Date = Date(),
    metadata: ProjectMetadata? = nil
  ) {
    self.path = path
    self.name = name
    self.lastOpenedAt = lastOpenedAt
    self.metadata = metadata
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(String.self, forKey: .path)
    name = try container.decode(String.self, forKey: .name)
    lastOpenedAt = try container.decode(Date.self, forKey: .lastOpenedAt)
    metadata = try? container.decodeIfPresent(ProjectMetadata.self, forKey: .metadata)
  }
}
