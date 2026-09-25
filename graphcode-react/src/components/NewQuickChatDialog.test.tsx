import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { NewQuickChatDialog } from "./NewQuickChatDialog";

describe("NewQuickChatDialog", () => {
  it("renders an accessible title and backend form", () => {
    const markup = renderToStaticMarkup(
      <NewQuickChatDialog
        onClose={() => undefined}
        onCreate={async () => undefined}
      />,
    );

    expect(markup).toContain('role="dialog"');
    expect(markup).toContain('aria-modal="true"');
    expect(markup).toContain("Chat title");
    expect(markup).toContain("GitHub Copilot CLI");
    expect(markup).toContain("Create and open");
  });
});
