import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { LiveRegion } from "./LiveRegion";

describe("LiveRegion", () => {
  it("uses one atomic polite status region", () => {
    const markup = renderToStaticMarkup(
      <LiveRegion message="Connected to graphcoded." />,
    );

    expect(markup).toContain('role="status"');
    expect(markup).toContain('aria-live="polite"');
    expect(markup).toContain('aria-atomic="true"');
    expect(markup).toContain("Connected to graphcoded.");
  });
});
