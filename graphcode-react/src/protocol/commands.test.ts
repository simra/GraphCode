import { describe, expect, it } from "vitest";
import {
  addressGraphCommand,
  armCompositeCommand,
  closeProjectCommand,
  completeNodeCommand,
  createEdgeCommand,
  createNodeCommand,
  createQuickChatCommand,
  deleteQuickChatCommand,
  deleteProjectGraphCommand,
  deleteNodeCommand,
  deleteEdgeCommand,
  forgetProjectCommand,
  listQuickChatsCommand,
  mailboxCommand,
  mailboxPostCommand,
  mailboxSearchCommand,
  mailboxUnreadCommand,
  mailroomPostCommand,
  mailroomWatchCommand,
  openQuickChatCommand,
  openProjectCommand,
  memoNodeCommand,
  messageNodeCommand,
  refreshUsageCommand,
  refineNodeCommand,
  pilotCompositeCommand,
  renameNodeCommand,
  renameQuickChatCommand,
  restartNodeCommand,
  resumeSessionCommand,
  rollbackRefinementCommand,
  stopNodeCommand,
  updateNodeCommand,
} from "./commands";

describe("daemon commands", () => {
  it("encodes the authoritative Quick Chat command labels", () => {
    expect(listQuickChatsCommand()).toEqual({ listQuickChats: {} });
    expect(createQuickChatCommand("Scratch", "claudeCode")).toEqual({
      createQuickChat: { title: "Scratch", backend: "claudeCode" },
    });
    expect(
      openQuickChatCommand("11111111-1111-4111-8111-111111111111"),
    ).toEqual({
      openQuickChat: { id: "11111111-1111-4111-8111-111111111111" },
    });
    expect(
      renameQuickChatCommand("11111111-1111-4111-8111-111111111111", "Renamed"),
    ).toEqual({
      renameQuickChat: {
        id: "11111111-1111-4111-8111-111111111111",
        title: "Renamed",
      },
    });
    expect(
      deleteQuickChatCommand("11111111-1111-4111-8111-111111111111"),
    ).toEqual({
      deleteQuickChat: { id: "11111111-1111-4111-8111-111111111111" },
    });
  });

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

  it("encodes playbook refinement and nested graph addressing", () => {
    const project = "C:\\work\\graph";
    const node = "33333333-3333-4333-8333-333333333333";
    expect(refineNodeCommand(project, node, "Use the verifier first")).toEqual({
      graphCommand: {
        projectPath: project,
        command: {
          refineNode: {
            _0: node,
            text: "Use the verifier first",
            from: null,
          },
        },
      },
    });
    expect(rollbackRefinementCommand(project, node)).toEqual({
      graphCommand: {
        projectPath: project,
        command: { rollbackRefinement: { _0: node, from: null } },
      },
    });
    expect(
      addressGraphCommand(deleteNodeCommand(project, node), [
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
      ]),
    ).toEqual({
      graphCommand: {
        projectPath: project,
        command: {
          subGraphCommand: {
            nodeID: "11111111-1111-4111-8111-111111111111",
            command: {
              subGraphCommand: {
                nodeID: "22222222-2222-4222-8222-222222222222",
                command: { deleteNode: { _0: node } },
              },
            },
          },
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

  it("encodes bounded Mailroom board reads and human posts", () => {
    const project = "C:\\work\\graph";
    expect(mailboxCommand(project)).toEqual({
      mailbox: {
        projectPath: project,
        query: {
          selection: { board: {} },
          search: null,
          fullBodies: true,
          advanceCursor: null,
        },
      },
    });
    expect(mailroomPostCommand(project, "Build is green", "build")).toEqual({
      graphCommand: {
        projectPath: project,
        command: {
          mailroomPost: {
            text: "Build is green",
            topic: "build",
            from: null,
          },
        },
      },
    });
    expect(mailboxSearchCommand(project, "green")).toEqual({
      mailbox: {
        projectPath: project,
        query: {
          selection: { board: {} },
          search: "green",
          fullBodies: true,
          advanceCursor: null,
        },
      },
    });
    expect(mailboxPostCommand(project, 42)).toEqual({
      mailbox: {
        projectPath: project,
        query: {
          selection: { post: { id: 42 } },
          search: null,
          fullBodies: true,
          advanceCursor: null,
        },
      },
    });
    expect(mailboxUnreadCommand(project, "reader", true)).toEqual({
      mailbox: {
        projectPath: project,
        query: {
          selection: { unread: { reader: "reader" } },
          search: null,
          fullBodies: null,
          advanceCursor: true,
        },
      },
    });
    expect(mailroomWatchCommand(project, "reader", true, "build")).toEqual({
      graphCommand: {
        projectPath: project,
        command: {
          mailroomWatch: {
            on: true,
            topic: "build",
            from: "reader",
          },
        },
      },
    });
  });

  it("encodes edge create and delete with the complete existing spec", () => {
    const project = "C:\\work\\graph";
    expect(
      createEdgeCommand(project, "source", "target", {
        kind: "handoff",
        condition: "onSuccess",
        payloadTransform: { template: { _0: "payload {{output}}" } },
        cycleGuard: {
          maxIterations: 3,
          until: "test -f done",
          stopAfterPassesWithoutImprovement: 2,
        },
        spawnTargetProjectPath: null,
      }),
    ).toEqual({
      graphCommand: {
        projectPath: project,
        command: {
          createEdge: {
            from: "source",
            to: "target",
            spec: {
              kind: "handoff",
              condition: "onSuccess",
              payloadTransform: {
                template: { _0: "payload {{output}}" },
              },
              cycleGuard: {
                maxIterations: 3,
                until: "test -f done",
                stopAfterPassesWithoutImprovement: 2,
              },
              spawnTargetProjectPath: null,
            },
          },
        },
      },
    });
    expect(deleteEdgeCommand(project, "edge")).toEqual({
      graphCommand: {
        projectPath: project,
        command: { deleteEdge: { _0: "edge" } },
      },
    });
  });
});
