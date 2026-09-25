import {
  useEffect,
  useRef,
  type KeyboardEvent as ReactKeyboardEvent,
  type RefObject,
} from "react";

const focusableSelector = [
  "button:not(:disabled)",
  "input:not(:disabled)",
  "select:not(:disabled)",
  "textarea:not(:disabled)",
  "a[href]",
  "summary",
  '[tabindex]:not([tabindex="-1"])',
].join(", ");

function focusableElements(container: HTMLElement): HTMLElement[] {
  return [...container.querySelectorAll<HTMLElement>(focusableSelector)].filter(
    (element) =>
      !element.hidden &&
      element.getAttribute("aria-hidden") !== "true" &&
      (!element.closest("details:not([open])") ||
        element.tagName === "SUMMARY"),
  );
}

export function useDialogFocus({
  active = true,
  canClose = true,
  initialFocusRef,
  onClose,
  selectInitial = false,
}: {
  active?: boolean;
  canClose?: boolean;
  initialFocusRef?: RefObject<HTMLElement | null>;
  onClose(): void;
  selectInitial?: boolean;
}) {
  const dialogRef = useRef<HTMLElement>(null);

  useEffect(() => {
    if (!active) return;
    const invoker =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : undefined;
    const target =
      initialFocusRef?.current ??
      (dialogRef.current ? focusableElements(dialogRef.current)[0] : undefined);
    target?.focus();
    if (
      selectInitial &&
      (target instanceof HTMLInputElement ||
        target instanceof HTMLTextAreaElement)
    ) {
      target.select();
    }
    return () => {
      if (invoker?.isConnected) invoker.focus();
    };
  }, [active, initialFocusRef, selectInitial]);

  function handleDialogKeyDown(event: ReactKeyboardEvent<HTMLElement>) {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      if (canClose) onClose();
      return true;
    }
    if (event.key !== "Tab" || !dialogRef.current) return false;
    const focusable = focusableElements(dialogRef.current);
    if (!focusable.length) {
      event.preventDefault();
      dialogRef.current.focus();
      return true;
    }
    const first = focusable[0];
    const last = focusable.at(-1)!;
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
      return true;
    }
    if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
      return true;
    }
    if (!dialogRef.current.contains(document.activeElement)) {
      event.preventDefault();
      (event.shiftKey ? last : first).focus();
      return true;
    }
    return false;
  }

  return { dialogRef, handleDialogKeyDown };
}
