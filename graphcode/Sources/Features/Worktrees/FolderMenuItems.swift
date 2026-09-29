import AppKit
import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The folder verbs worktree hygiene adds, shared between the sidebar row's menu and
/// the lane caption's — a lane band *is* the folder, so right-clicking either place
/// must offer the same things.
///
/// The trailing count on `Worktrees…` is the whole reason the item earns a slot: it
/// answers "is there anything to reclaim" without opening anything. With nothing
/// reclaimable the item stays, without a count.
struct FolderHygieneMenuItems: View {
  let store: StoreOf<AppFeature>
  let project: ProjectRef

  var body: some View {
    if AppWorktreesReducer.tracksWorktrees(project.path) {
      Button(worktreesTitle) {
        store.send(.worktrees(.sweepRequested(projectPath: project.path)))
      }
      Button("Project Settings…") {
        store.send(.worktrees(.settingsRequested(projectPath: project.path)))
      }
    }
    if project.metadata?.capabilities.revealInFileManager == true {
      Button("Open in Finder") {
        NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
      }
    }
  }

  private var worktreesTitle: String {
    let reclaimable = store.worktreeStats[project.path]?.reclaimable ?? 0
    return reclaimable > 0 ? "Worktrees… \(reclaimable)" : "Worktrees…"
  }
}
