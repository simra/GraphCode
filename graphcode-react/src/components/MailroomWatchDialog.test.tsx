import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { MailroomWatchDialog } from "./MailroomWatchDialog";

describe("MailroomWatchDialog", () => {
  it("renders accessible off, all, and topic scopes", () => {
    const markup = renderToStaticMarkup(
      <MailroomWatchDialog
        nodeTitle="Verifier"
        currentTopic="build"
        watching
        onClose={() => undefined}
        onSave={async () => undefined}
      />,
    );

    expect(markup).toContain('role="dialog"');
    expect(markup).toContain("Watch for Verifier");
    expect(markup).toContain("All posts");
    expect(markup).toContain("One topic");
    expect(markup).toContain('value="build"');
  });
});
