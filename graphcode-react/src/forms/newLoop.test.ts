import { describe, expect, it } from "vitest";
import { buildNodeDraft, initialNewLoopForm, validateNewLoop } from "./newLoop";

describe("New Loop draft", () => {
  it("validates required fields by loop type", () => {
    expect(
      validateNewLoop({ ...initialNewLoopForm, loopType: "sketch" }),
    ).toEqual({});
    expect(
      validateNewLoop({ ...initialNewLoopForm, loopType: "turnBased" }),
    ).toHaveProperty("firstInstruction");
    expect(
      validateNewLoop({ ...initialNewLoopForm, loopType: "goalBased" }),
    ).toHaveProperty("goalSummary");
    expect(
      validateNewLoop({ ...initialNewLoopForm, loopType: "timeBased" }),
    ).toHaveProperty("triggerPrompt");
    expect(
      validateNewLoop({ ...initialNewLoopForm, loopType: "proactive" }),
    ).toHaveProperty("title");
  });

  it("enforces backend recurrence and composite capabilities", () => {
    expect(
      validateNewLoop({
        ...initialNewLoopForm,
        loopType: "timeBased",
        triggerPrompt: "Run tests",
        backend: "codex",
        cadenceMode: "session",
      }),
    ).toHaveProperty("backend");
    expect(
      validateNewLoop({
        ...initialNewLoopForm,
        loopType: "timeBased",
        triggerPrompt: "Run tests",
        backend: "codex",
        cadenceMode: "daemon",
      }),
    ).toEqual({});
    expect(
      validateNewLoop({
        ...initialNewLoopForm,
        loopType: "proactive",
        title: "Routine",
        backend: "openCode",
      }),
    ).toHaveProperty("backend");
  });

  it("builds every current NodeDraft field without fake attachment/template data", () => {
    const draft = buildNodeDraft(
      {
        ...initialNewLoopForm,
        title: "Improve coverage",
        loopType: "goalBased",
        goalSummary: "Coverage is above 80%",
        goalPredicate: "test $(coverage) -gt 80",
        metricCommand: "coverage",
        metricDirection: "maximize",
        tokenBudget: "12000",
        stallAfterSeconds: "3600",
        skipsUnchangedWorkspace: true,
        backend: "copilotCLI",
        modelTier: "capable",
        bindWorktree: true,
        worktreeId: "feature",
        worktreeRepositoryPath: "C:\\work\\graph",
        worktreePath: "C:\\work\\graph-feature",
        worktreeBranch: "feature",
      },
      "11111111-1111-4111-8111-111111111111",
    );

    expect(draft.goal).toMatchObject({
      summary: "Coverage is above 80%",
      tokenBudget: 12000,
      stallAfterSeconds: 3600,
      skipsUnchangedWorkspace: true,
    });
    expect(draft.worktree?.branch).toBe("feature");
    expect(draft.attachments).toEqual([]);
    expect(draft.createdFromTemplateID).toBeNull();
    expect(draft.templateFollow).toBeNull();
  });
});
