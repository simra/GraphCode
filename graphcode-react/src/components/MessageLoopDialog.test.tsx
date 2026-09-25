import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { MessageLoopDialog } from "./MessageLoopDialog";

describe("MessageLoopDialog", () => {
  it("explains immediate and follow-up delivery semantics", () => {
    const markup = renderToStaticMarkup(
      <MessageLoopDialog
        nodeTitle="Worker"
        onClose={() => undefined}
        onSend={async () => undefined}
      />,
    );
    expect(markup).toContain('role="dialog"');
    expect(markup).toContain("Message Worker");
    expect(markup).toContain("Deliver when idle");
    expect(markup).toContain("Send now");
  });
});
