import Dependencies
import Foundation
import GraphcodeKit

/// The template library, as the app sees it — the bridge between
/// `TemplateStorage` (pure Foundation, shared with the daemon) and the form.
///
/// The watch stream is what makes the library live: an external edit or a `git
/// pull` shows up without a relaunch, which is the design's whole argument for
/// reading templates from files rather than holding them in the app.
struct TemplateLibraryClient: Sendable {
  var load: @Sendable (_ project: ProjectRef?) async -> [PromptTemplate]
  /// Saves and answers what actually landed — a read-only checkout falls back to
  /// home, and the caller says so rather than pretending the save went where it
  /// was asked.
  var save:
    @Sendable (_ template: PromptTemplate, _ origin: TemplateOrigin, _ projectPath: String?)
      async throws -> (template: PromptTemplate, origin: TemplateOrigin)
  /// Answers with the template as it landed — origin *and* filename, because a
  /// destination that already holds a template of that name gives it another.
  var move:
    @Sendable (_ template: PromptTemplate, _ destination: TemplateOrigin, _ projectPath: String?)
      async throws -> PromptTemplate
  var delete: @Sendable (_ template: PromptTemplate) async throws -> Void
  /// Fires once per change to either location while the stream lives.
  var watch: @Sendable (_ project: ProjectRef?) -> AsyncStream<Void>
  /// Resolves a template by id — the same read the daemon performs when a
  /// following loop next runs.
  var template: @Sendable (_ id: UUID, _ project: ProjectRef?) async -> PromptTemplate?
  /// Whether a project folder can take a `.graphcode/templates` — the save sheet
  /// greys the project option out rather than offering a save that falls back
  /// silently. Answering must not *create* the folder: nothing lands in a checkout
  /// until a save asks for it.
  var projectIsWritable: @Sendable (_ project: ProjectRef) -> Bool
  /// One more use of this template, as the picker counts them. App-local: applying a
  /// template must never write to the file, which may live in a repository.
  var recordUse: @Sendable (_ template: PromptTemplate) -> Void
  /// Writes the briefs the app ships with, once, on a library that has never been
  /// seeded — an empty ⌘T picker teaches nothing. See `StarterTemplates`.
  var seedStarters: @Sendable () async -> Void
}

extension TemplateLibraryClient: DependencyKey {
  static let liveValue = TemplateLibraryClient(
    load: { project in
      if let project {
        do {
          let templates = try await RemoteAssetClient.liveValue.templates(project.path)
          return overlayUseCounts(templates)
        } catch {
          let metadata =
            project.metadata ?? ProjectMetadata.inferred(fromProjectPath: project.path)
          if metadata.location != .local { return [] }
        }
      }
      let projectPath = project?.path
      let storage = TemplateStorage.shared
      let templates = await Task.detached(priority: .userInitiated) {
        storage.load(projectPath: projectPath)
      }.value
      return overlayUseCounts(templates)
    },
    save: { template, origin, projectPath in
      try await Task.detached(priority: .userInitiated) {
        try TemplateStorage.shared.save(template, to: origin, projectPath: projectPath)
      }.value
    },
    move: { template, destination, projectPath in
      try await Task.detached(priority: .userInitiated) {
        try TemplateStorage.shared.move(template, to: destination, projectPath: projectPath)
      }.value
    },
    delete: { template in
      try await Task.detached(priority: .userInitiated) {
        try TemplateStorage.shared.delete(template)
      }.value
    },
    watch: { project in
      let metadata =
        project.flatMap(\.metadata)
        ?? project.map { ProjectMetadata.inferred(fromProjectPath: $0.path) }
      guard metadata?.location != .ssh, metadata?.location != .codespace else {
        return AsyncStream { $0.finish() }
      }
      return TemplateStorage.shared.watch(projectPath: project?.path)
    },
    template: { id, project in
      if let project {
        if let templates = try? await RemoteAssetClient.liveValue.templates(project.path) {
          return templates.first(where: { $0.id == id })
        }
        let metadata =
          project.metadata ?? ProjectMetadata.inferred(fromProjectPath: project.path)
        if metadata.location != .local { return nil }
      }
      await Task.detached(priority: .userInitiated) {
        TemplateStorage.shared.template(withID: id, projectPath: project?.path)
      }.value
    },
    projectIsWritable: { project in
      let metadata =
        project.metadata ?? ProjectMetadata.inferred(fromProjectPath: project.path)
      guard metadata.location == .local else { return false }
      let storage = TemplateStorage.shared
      return storage.canWrite(to: storage.projectDirectory(project.path))
    },
    recordUse: { template in
      bumpUseCount(for: template)
    },
    seedStarters: {
      await Task.detached(priority: .utility) {
        _ = try? TemplateStorage.shared.seedStartersIfNeeded()
      }.value
    }
  )

  static let testValue = TemplateLibraryClient(
    load: { _ in [] },
    save: { _, _, _ in (PromptTemplate(name: "", body: ""), .home) },
    move: { template, _, _ in template },
    delete: { _ in },
    watch: { _ in AsyncStream { $0.finish() } },
    template: { _, _ in nil },
    projectIsWritable: { _ in false },
    recordUse: { _ in },
    seedStarters: {}
  )

  /// The use count is app-local (UserDefaults, keyed on filename + origin) and is
  /// never written back into a file — applying a template must not dirty a
  /// repository's working tree. See `PromptTemplate.useCount`.
  static func overlayUseCounts(_ templates: [PromptTemplate]) -> [PromptTemplate] {
    let defaults = UserDefaults.standard
    return templates.map { template in
      var overlaid = template
      overlaid.useCount = defaults.integer(forKey: Self.useCountKey(template))
      return overlaid
    }
  }

  private static func bumpUseCount(for template: PromptTemplate) {
    let defaults = UserDefaults.standard
    let key = Self.useCountKey(template)
    defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
  }

  private static func useCountKey(_ template: PromptTemplate) -> String {
    let origin: String
    switch template.origin {
    case .home: origin = "home"
    case .project(let path): origin = path
    }
    return "templateUseCount.\(origin).\(template.fileName)"
  }
}

extension DependencyValues {
  var templateLibrary: TemplateLibraryClient {
    get { self[TemplateLibraryClient.self] }
    set { self[TemplateLibraryClient.self] = newValue }
  }
}
