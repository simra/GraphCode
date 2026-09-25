import { describe, expect, it } from "vitest";
import { createNodeCommand, stopNodeCommand } from "./commands";

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
});
