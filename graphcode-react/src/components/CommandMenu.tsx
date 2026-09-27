import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
} from "react";
import { createPortal } from "react-dom";
import type { AppCommand } from "../commands/registry";

const viewportPadding = 8;
const menuGap = 6;
const menuWidth = 240;

interface MenuPosition {
  left: number;
  top: number;
  maxHeight: number;
}

export function CommandMenu({
  commands,
  pendingCommandId,
  onExecute,
}: {
  commands: AppCommand[];
  pendingCommandId?: string;
  onExecute(command: AppCommand): void;
}) {
  const menuId = useId();
  const triggerRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const focusMenuRef = useRef(false);
  const [open, setOpen] = useState(false);
  const [position, setPosition] = useState<MenuPosition>();

  const updatePosition = useCallback(() => {
    const trigger = triggerRef.current;
    if (!trigger) return;
    const rect = trigger.getBoundingClientRect();
    const measuredHeight = menuRef.current?.offsetHeight ?? 320;
    const availableWidth = Math.max(0, window.innerWidth - viewportPadding * 2);
    const width =
      menuRef.current?.offsetWidth || Math.min(menuWidth, availableWidth);
    const spaceBelow = window.innerHeight - rect.bottom - viewportPadding;
    const spaceAbove = rect.top - viewportPadding;
    const placeBelow =
      spaceBelow >= Math.min(measuredHeight, 240) || spaceBelow >= spaceAbove;
    const maxHeight = Math.max(
      80,
      (placeBelow ? spaceBelow : spaceAbove) - menuGap,
    );
    const top = placeBelow
      ? rect.bottom + menuGap
      : Math.max(
          viewportPadding,
          rect.top - Math.min(measuredHeight, maxHeight) - menuGap,
        );
    const left = Math.min(
      Math.max(viewportPadding, window.innerWidth - width - viewportPadding),
      Math.max(viewportPadding, rect.right - width),
    );
    setPosition({ left, top, maxHeight });
  }, []);

  const close = useCallback((restoreFocus: boolean) => {
    focusMenuRef.current = false;
    setOpen(false);
    setPosition(undefined);
    if (restoreFocus) triggerRef.current?.focus();
  }, []);

  const openMenu = useCallback(() => {
    focusMenuRef.current = true;
    setOpen(true);
  }, []);

  useLayoutEffect(() => {
    if (!open) return;
    updatePosition();
  }, [open, updatePosition]);

  useLayoutEffect(() => {
    if (!open || !position || !focusMenuRef.current) return;
    focusMenuRef.current = false;
    menuRef.current
      ?.querySelector<HTMLButtonElement>("button:not(:disabled)")
      ?.focus();
  }, [open, position]);

  useEffect(() => {
    if (!open) return;
    function handlePointerDown(event: PointerEvent) {
      const target = event.target as Node;
      if (
        triggerRef.current?.contains(target) ||
        menuRef.current?.contains(target)
      ) {
        return;
      }
      close(false);
    }
    function handleKeyDown(event: KeyboardEvent) {
      if (event.key !== "Escape") return;
      event.preventDefault();
      close(true);
    }
    function handleScroll(event: Event) {
      if (menuRef.current?.contains(event.target as Node)) return;
      updatePosition();
    }
    window.addEventListener("resize", updatePosition);
    window.addEventListener("scroll", handleScroll, true);
    document.addEventListener("pointerdown", handlePointerDown);
    document.addEventListener("keydown", handleKeyDown, true);
    return () => {
      window.removeEventListener("resize", updatePosition);
      window.removeEventListener("scroll", handleScroll, true);
      document.removeEventListener("pointerdown", handlePointerDown);
      document.removeEventListener("keydown", handleKeyDown, true);
    };
  }, [close, open, updatePosition]);

  function handleMenuKeyDown(event: ReactKeyboardEvent<HTMLDivElement>) {
    const items = [
      ...event.currentTarget.querySelectorAll<HTMLButtonElement>(
        "button:not(:disabled)",
      ),
    ];
    const currentIndex = items.indexOf(
      document.activeElement as HTMLButtonElement,
    );
    const nextIndex =
      event.key === "ArrowDown"
        ? (currentIndex + 1) % items.length
        : event.key === "ArrowUp"
          ? (currentIndex - 1 + items.length) % items.length
          : event.key === "Home"
            ? 0
            : event.key === "End"
              ? items.length - 1
              : undefined;
    if (nextIndex === undefined || !items.length) {
      if (event.key === "Tab") close(false);
      return;
    }
    event.preventDefault();
    items[nextIndex]?.focus();
  }

  return (
    <div className="command-menu">
      <button
        ref={triggerRef}
        type="button"
        aria-label="More loop actions"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        onClick={() => {
          if (open) {
            close(false);
          } else {
            openMenu();
          }
        }}
        onKeyDown={(event) => {
          if (event.key !== "ArrowDown") return;
          event.preventDefault();
          openMenu();
        }}
      >
        More
      </button>
      {open
        ? createPortal(
            <div
              ref={menuRef}
              id={menuId}
              className="command-menu-popover"
              role="menu"
              aria-label="More loop actions"
              style={{
                position: "fixed",
                zIndex: 200,
                left: position?.left ?? viewportPadding,
                top: position?.top ?? viewportPadding,
                maxHeight: position?.maxHeight,
                visibility: position ? "visible" : "hidden",
              }}
              onKeyDown={handleMenuKeyDown}
            >
              {commands.map((command) => (
                <button
                  key={command.id}
                  type="button"
                  role="menuitem"
                  className={command.danger ? "command-danger" : undefined}
                  disabled={!command.enabled || pendingCommandId === command.id}
                  title={command.disabledReason}
                  onClick={() => {
                    onExecute(command);
                    close(true);
                  }}
                >
                  <span>{command.label}</span>
                  {command.shortcut ? (
                    <kbd>{command.shortcut.label}</kbd>
                  ) : null}
                </button>
              ))}
            </div>,
            document.body,
          )
        : null}
    </div>
  );
}
