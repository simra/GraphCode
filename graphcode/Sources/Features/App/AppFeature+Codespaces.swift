import ComposableArchitecture
import GraphcodeKit

extension AppFeature {
  /// Selecting any loop of a codespace is a human asking for that codespace now (issue
  /// #480): its dialers restart their retry schedule and redial, from a hold or a pause.
  /// Called from `.nodeTapped`, which every click, key and palette selection reaches —
  /// blocked loops included, which `openNode` returns early for — and from Back/Forward,
  /// which deliberately does not.
  func resumeCodespace(_ project: ProjectRef?) -> Effect<Action> {
    guard project?.metadata?.location == .codespace,
      let project,
      let location = Self.codespace(atProjectPath: project.path)
    else { return .none }
    @Dependency(\.codespaceReconnect) var codespaceReconnect
    return .run { _ in codespaceReconnect.request(location) }
  }

  static func codespace(atProjectPath projectPath: String) -> RemoteProjectLocation? {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath),
      location.isCodespace
    else { return nil }
    return location
  }
}
