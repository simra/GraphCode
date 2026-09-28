import Foundation
import Testing

@testable import GraphcodeKit

@Suite
struct AttendedSessionLaunchTests {
  @Test
  func blankSketchUsesTheConfiguredBackendLaunchPlan() {
    let node = LoopNode(
      title: "Main", loopType: .sketch, backend: .claudeCode, modelTier: .capable)
    let arguments =
      ZmxSessionLauncher.arguments(
        forNode: node,
        settings: GraphcodeSettings(autoSelectsModel: true),
        allowsEmptyPrompt: true) ?? []

    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    #expect(Array(arguments.prefix(3)) == ["run", name, "-d"])
    #expect(arguments.contains("claude"))
    #expect(arguments.contains("--model"))
    #expect(arguments.contains("opus"))
  }

  @Test
  func blankSketchStillReceivesBriefingConfiguration() {
    let briefing = "C:\\graphcode\\briefings\\project\\AGENTS.md"
    let claude = CLISessionBackendKind.claudeCode.launchArguments(
      prompt: nil, tier: .standard, briefingPath: briefing)
    let copilot = CLISessionBackendKind.copilotCLI.launchArguments(
      prompt: nil, tier: .standard, briefingPath: briefing,
      settings: GraphcodeSettings(copilotPermissions: .allowTools))

    #expect(claude.suffix(2) == ["--append-system-prompt-file", briefing])
    #expect(copilot.contains("--add-dir"))
    #expect(!copilot.contains("--interactive"))
  }
}
