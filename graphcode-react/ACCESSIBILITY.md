# Accessibility validation

GraphCode React combines automated semantic checks with Windows WebView and Narrator
testing. Automated tests catch deterministic markup regressions; they do not replace
screen-reader, focus, touch, zoom, high-contrast, or DPI verification in the packaged
Tauri application.

## Automated checks

Run:

```powershell
npm run test:a11y
```

The axe-core/jsdom suite checks representative graph, nested project hierarchy,
Mailroom list/detail, and modal edge-editor markup. It runs as part of `npm test`.
The color-contrast rule is disabled because jsdom does not compute the real CSS color
cascade; contrast remains a packaged-application manual gate.

When adding a destination or interaction:

1. Include it in `src/accessibility.test.tsx` when it has stable server-renderable
   markup.
2. Keep controls named, keyboard reachable, and associated with visible headings or
   labels.
3. Do not suppress an axe rule globally unless the browser-less environment cannot
   evaluate it. Document that limitation here.

## Packaged WebView automation boundary

This repository does not currently have an executable packaged-WebView automation
harness. It has no `tauri-driver`, WebDriver, Playwright browser project, desktop CI
session, or fixture-daemon lifecycle for an installed application, and Tauri bundling
is currently disabled. Optional browser-provider names in Vitest's lockfile metadata
do not constitute a configured runner.

Do not treat the jsdom axe suite as a packaged-app result. Adding reliable automation
is a separate packaging task that must first establish a bundled test artifact, pin a
driver compatible with the supported WebView2 runtime, provision an interactive Windows
CI desktop, and start a protocol-valid fixture daemon. Until that infrastructure exists,
the Narrator, focus, touch, DPI, contrast, and real-WebView gates below remain manual
release checks.

## Windows Narrator smoke test

Use a packaged or `npm run tauri dev` build on Windows with display scaling at both
100% and 150%. Test once with a live daemon and once with fixture fallback. Start
Narrator with `Win+Ctrl+Enter`; use `Narrator+Space` to switch scan mode when needed.

### Shell and project hierarchy

1. Tab from the window start through Quick Chats, project rows, Mailroom, and the
   selected project's loop hierarchy.
2. Confirm Narrator announces each loop's title, type, and state, and identifies the
   currently selected loop.
3. Expand and collapse a composite, open its child graph, and select a nested loop.
4. Confirm the breadcrumb, canvas selection, inspector heading, and sidebar selection
   all identify the same loop. Returning to the project breadcrumb must restore the
   root hierarchy without losing keyboard access.

### Graph canvas

1. Tab to a loop. Use all four arrow keys and confirm focus moves spatially and the
   focused loop is announced.
2. Press `Home`, `End`, `Enter`, and `Space`; confirm focus and selected state are
   announced without an unexpected viewport jump.
3. Use `Alt+Arrow` to reposition a loop, restart the application, and confirm the
   position is restored. Run **Reset Layout** from the command palette and confirm the
   deterministic layout returns.
4. Tab to an edge and select it with `Enter` or `Space`. Confirm source, destination,
   kind, and fired count are announced. Delete only a stable-ID edge and verify the
   confirmation defaults to cancellation.
5. Open **New Edge** from the command palette and complete the endpoint selectors
   without using a pointer. Focus must remain trapped in the dialog, `Escape` must
   close it, and the daemon-confirmed edge must appear before success is implied.

### Zoom, touch, and hit testing

1. Place the pointer over a loop and use the wheel. The same graph point must remain
   under the pointer while zooming.
2. On a touch display, pinch around a loop while translating the midpoint. The loop
   must remain under the midpoint and a post-pinch tap must not activate it.
3. At minimum and maximum zoom, select nodes, drag a node, and create an edge. Hit
   targets and preview geometry must remain aligned.

### Mailroom and dialogs

1. Open project Mailroom, move through the post list, and confirm author, topic, post
   number, and selected detail heading are announced.
2. Run Refresh, Search, Post, and Load Complete Post. Errors must be announced through
   the visible alert and no cursor movement may be implied for board/search reads.
3. Open New Loop, Edit Loop, message, Mailroom post/watch, and text dialogs. Verify the
   title is announced, initial focus is useful, Tab is trapped, and `Escape` restores
   focus to the invoking surface.

### Visual and focus gates

1. Enable Windows Contrast Themes and confirm selection, focus, loop type, state, and
   fired edges remain distinguishable without relying on color.
2. At 100%, 150%, and 200% scaling, confirm the sidebar, Mailroom, graph, inspector,
   command palette, and dialogs do not hide focused controls or require horizontal
   page scrolling.
3. Disconnect and reconnect graphcoded while focus is in the sidebar and canvas.
   Status and errors must be announced without stealing focus.

Record the Windows version, WebView2 version, scaling, input method, daemon mode, and
the first failing step when filing an accessibility issue.
