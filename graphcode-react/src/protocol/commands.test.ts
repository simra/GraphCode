import { describe, expect, it } from "vitest";
import {
  armCompositeCommand,
  closeProjectCommand,
  completeNodeCommand,
  createNodeCommand,
  deleteProjectGraphCommand,
  deleteNodeCommand,
  forgetProjectCommand,
  openProjectCommand,
  memoNodeCommand,
  messageNodeCommand,
  refreshUsageCommand,
  pilotCompositeCommand,
  renameNodeCommand,
  restartNodeCommand,
  resumeSessionCommand,
  stopNodeCommand,
  updateNodeCommand,
} from "./commands";

describe("daemon commands", () => {
  it("encodes stopNode with Swift Codable's single-value wrapper", () => {
    expect(
      stopNodeCommand(
        "C:\\work\\graph",
        "11111111-1111-4111-8111-111111111111",
      ),
    ).toEqual({
      graphCommand: {
        projectPath: "C:\\work\\graph",
        command: {
          stopNode: { _0: "11111111-1111-4111-8111-111111111111" },
        },
      },
    });
  });

  it("encodes createNode through graphCommand with the NodeDraft wrapper", () => {
    const command = createNodeCommand("C:\\work\\graph", {
      id: "11111111-1111-4111-8111-111111111111",
      title: "Ship",
      loopType: "goalBased",
      checkDescription: null,
      triggerPrompt: null,
      heartbeatIntervalSeconds: null,
      firstInstruction: null,
      pausesBeforeWritesOnly: false,
      attachments: [],
      goal: {
        summary: "All tests pass",
        predicate: "swift test",
        pollIntervalSeconds: 60,
        stallAfterSeconds: null,
        metricCommand: null,
        metricDirection: "maximize",
        tokenBudget: null,
        skipsUnchangedWorkspace: false,
      },
      backend: null,
      modelTier: null,
      worktree: null,
      subGraph: null,
      createdBy: null,
      createdFromTemplateID: null,
      templateFollow: null,
    });

    expect(
      command.graphCommand.command.createNode._0.goal?.pollIntervalSeconds,
    ).toBe(60);
    expect(command.graphCommand.command.createNode._0.loopType).toBe(
      "goalBased",
    );
  });

  it("encodes existing lifecycle commands with Swift associated-value labels", () => {
    const project = "C:\\work\\graph";
    const node = "11111111-1111-4111-8111-111111111111";

    expect(renameNodeCommand(project, node, "Renamed")).toEqual({
      graphCommand: {
        projectPath: project,
        command: { renameNode: { _0: node, title: "Renamed" } },
      },
    });
    expect(restartNodeCommand(project, node).graphCommand.command).toEqual({
      restartNode: { _0: node },
    });
    expect(resumeSessionCommand(project, node).graphCommand.command).toEqual({
      resumeSession: { _0: node },
    });
    expect(deleteNodeCommand(project, node).graphCommand.command).toEqual({
      deleteNode: { _0: node },
    });
    expect(completeNodeCommand(project, node, "Shipped")).toEqual({
      graphCommand: {
        projectPath: project,
        command: {
          completeNode: { _0: node, result: "Shipped", from: null },
        },
      },
    });
    expect(refreshUsageCommand(project).graphCommand.command).toEqual({
      refreshUsage: {},
    });
  });

  it("encodes project opening with the authoritative labeled path", () => {
    expect(openProjectCommand("C:\\work\\graph")).toEqual({
      openProject: { path: "C:\\work\\graph" },
    });
  });

  it("encodes project lifecycle commands with labeled paths", () => {
    const path = "C:\\work\\graph";
    expect(closeProjectCommand(path)).toEqual({ closeProject: { path } });
    expect(forgetProjectCommand(path)).toEqual({ forgetProject: { path } });
    expect(deleteProjectGraphCommand(path)).toEqual({
      deleteProjectGraph: { path },
    });
  });

  it("encodes partial NodeUpdate fields without inventing immutable changes", () => {
    expect(
      updateNodeCommand(
        "C:\\work\\graph",
        "11111111-1111-4111-8111-111111111111",
        {
          goalPredicate: "",
          tokenBudget: 0,
          modelTier: "fast",
          updatedBy: null,
        },
      ),
    ).toEqual({
      graphCommand: {
        projectPath: "C:\\work\\graph",
        command: {
          updateNode: {
            _0: "11111111-1111-4111-8111-111111111111",
            update: {
              goalPredicate: "",
              tokenBudget: 0,
              modelTier: "fast",
              updatedBy: null,
            },
          },
        },
      },
    });
  });

  it("encodes immediate, follow-up, and memo writes with human attribution", () => {
    const project = "C:\\work\\graph";
    const node = "11111111-1111-4111-8111-111111111111";
    expect(messageNodeCommand(project, node, "Now", false)).toEqual({
      graphCommand: {
        projectPath: project,
        command: {
          messageNode: { _0: node, text: "Now", from: null },
        },
      },
    });
    expect(messageNodeCommand(project, node, "Later", true)).toEqual({
      graphCommand: {
        projectPath: project,
        command: {
          messageNode: {
            _0: node,
            text: "Later",
            from: null,
            followUp: true,
          },
        },
      },
    });
    expect(memoNodeCommand(project, node, "Remember this")).toEqual({
      graphCommand: {
        projectPath: project,
        command: {
          memoNode: { _0: node, text: "Remember this", from: null },
        },
      },
    });
  });

  it("encodes composite pilot and arm commands as unary UUID cases", () => {
    const project = "C:\\work\\graph";
    const node = "11111111-1111-4111-8111-111111111111";
    expect(pilotCompositeCommand(project, node)).toEqual({
      graphCommand: {
        projectPath: project,
        command: { pilotComposite: { _0: node } },
      },
    });
    expect(armCompositeCommand(project, node)).toEqual({
      graphCommand: {
        projectPath: project,
        command: { armComposite: { _0: node } },
      },
    });
  });
});
