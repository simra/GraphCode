import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { MailroomView } from "./MailroomView";

describe("MailroomView", () => {
  it("renders project posts, deep-read metadata, and project controls", () => {
    const markup = renderToStaticMarkup(
      <MailroomView
        graph={{
          id: "graph",
          project: { path: "C:\\project", name: "Project" },
          nodes: [],
          edges: [],
        }}
        mailbox={{
          posts: [
            {
              id: 7,
              at: "2026-09-25T10:00:00Z",
              author: "Planner",
              topic: "Release",
              body: "Ship the frontend.",
              kind: "letter",
            },
          ],
          bodiesTrimmed: true,
          digest: { count: 1, latestID: 7, fingerprint: 7 },
          remaining: 0,
          prunedUnread: 0,
        }}
        commands={[
          {
            id: "loop.mailroomRefresh",
            label: "Refresh Mailroom",
            description: "Refresh",
            category: "Project",
            surfaces: ["mailroom"],
            enabled: true,
            execute: () => undefined,
          },
        ]}
        commandsForPost={() => [
          {
            id: "mailroom.readPost",
            label: "Load Complete Post",
            description: "Read",
            category: "Project",
            surfaces: ["mailroom"],
            enabled: true,
            execute: () => undefined,
          },
        ]}
        onBack={() => undefined}
        onExecute={() => undefined}
      />,
    );

    expect(markup).toContain("Project Mailroom");
    expect(markup).toContain("Release");
    expect(markup).toContain("Ship the frontend.");
    expect(markup).toContain("Load Complete Post");
  });
});
