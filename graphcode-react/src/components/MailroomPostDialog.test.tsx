import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { MailroomPostDialog } from "./MailroomPostDialog";

describe("MailroomPostDialog", () => {
  it("explains project-wide delivery and byte limits", () => {
    const markup = renderToStaticMarkup(
      <MailroomPostDialog
        projectName="Graph"
        onClose={() => undefined}
        onPost={async () => undefined}
      />,
    );
    expect(markup).toContain("Post to Graph");
    expect(markup).toContain("visible to every loop");
    expect(markup).toContain("1,024 UTF-8 bytes");
  });
});
