import { useEffect, useRef, type ReactNode } from "react";

export function InspectorPane({
  selectionKey,
  onClose,
  children,
}: {
  selectionKey?: string;
  onClose(): void;
  children: ReactNode;
}) {
  const paneRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!selectionKey) return;
    const scrollRegion =
      paneRef.current?.querySelector<HTMLElement>(".inspector-scroll");
    if (scrollRegion) scrollRegion.scrollTop = 0;
  }, [selectionKey]);

  useEffect(() => {
    if (!selectionKey) return;
    function handleKeyDown(event: KeyboardEvent) {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      if (document.querySelector(".command-menu-popover")) return;
      onClose();
    }
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [onClose, selectionKey]);

  return (
    <div
      ref={paneRef}
      className={`inspector-pane ${
        selectionKey ? "inspector-pane-open" : "inspector-pane-empty"
      }`}
      data-inspector-state={selectionKey ? "open" : "empty"}
    >
      {selectionKey ? (
        <button
          className="inspector-sheet-backdrop"
          type="button"
          tabIndex={-1}
          aria-label="Close inspector"
          onClick={onClose}
        />
      ) : null}
      <div className="inspector-pane-content">{children}</div>
    </div>
  );
}
