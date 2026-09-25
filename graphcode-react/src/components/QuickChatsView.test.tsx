import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { AppCommand } from "../commands/registry";
import { QuickChatsView } from "./QuickChatsView";

const commands: AppCommand[] = [
  {
    id: "chat.open",
    label: "Open Chat",
    description: "Open",
    category: "Application",
    surfaces: [],
    enabled: true,
    execute: () => undefined,
  },
  {
    id: "chat.rename",
    label: "Rename Chat",
    description: "Rename",
    category: "Application",
    surfaces: [],
    enabled: true,
    execute: () => undefined,
  },
  {
    id: "chat.delete",
    label: "Delete Chat",
    description: "Delete",
    category: "Application",
    surfaces: [],
    enabled: true,
    danger: true,
    execute: () => undefined,
  },
];

const chat = {
  id: "11111111-1111-4111-8111-111111111111",
  title: "Scratch",
  backend: "claudeCode",
  createdAt: 0,
  activity: { sequence: 2, text: "editing" },
};

describe("QuickChatsView", () => {
  it("renders stable chat identity and lifecycle controls", () => {
    const markup = renderToStaticMarkup(
      <QuickChatsView
        chats={[chat]}
        commandsForChat={() => commands}
        onBack={() => undefined}
        onNewChat={() => undefined}
        onExecute={() => undefined}
      />,
    );

    expect(markup).toContain("Scratch");
    expect(markup).toContain("editing");
    expect(markup).toContain("Actions for Scratch");
    expect(markup).toContain("Delete Chat");
  });

  it("renders the confirmed workspace without inventing terminal support", () => {
    const markup = renderToStaticMarkup(
      <QuickChatsView
        chats={[chat]}
        selectedChat={chat}
        commandsForChat={() => commands}
        onBack={() => undefined}
        onNewChat={() => undefined}
        onExecute={() => undefined}
      />,
    );

    expect(markup).toContain("Quick Chat workspace");
    expect(markup).toContain("graphcoded confirmed");
    expect(markup).toContain("zmx bridge");
  });
});
