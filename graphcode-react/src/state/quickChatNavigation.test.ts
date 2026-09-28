import { describe, expect, it, vi } from "vitest";
import type { AppState } from "./graphState";
import { appReducer, initialAppState } from "./graphState";
import {
  activateQuickChat,
  pendingCreatedQuickChatRoute,
} from "./quickChatNavigation";

function quickChatState(selectedQuickChatId?: string): AppState {
  return {
    ...initialAppState,
    connection: { phase: "connected", usingFixture: false },
    quickChatsSelected: selectedQuickChatId !== undefined,
    selectedQuickChatId,
    quickChats: [
      {
        id: "chat-a",
        title: "Scratch",
        backend: "copilot",
        createdAt: "2026-09-28T10:00:00Z",
      },
    ],
  };
}

describe("Quick Chat navigation activation", () => {
  it("does not reopen an already active Quick Chat", async () => {
    const send = vi.fn();

    await expect(
      activateQuickChat(quickChatState("chat-a"), "chat-a", send),
    ).resolves.toEqual({ activated: true });
    expect(send).not.toHaveBeenCalled();
  });

  it("uses the normal daemon activation and requires matching confirmation", async () => {
    const response = {
      version: 2 as const,
      kind: "response" as const,
      requestID: "request",
      event: {
        type: "quickChatChanged" as const,
        chat: quickChatState().quickChats[0],
      },
    };
    const send = vi.fn(async () => response);

    await expect(
      activateQuickChat(quickChatState(), "chat-a", send),
    ).resolves.toEqual({ activated: true, envelope: response });
    expect(send).toHaveBeenCalledWith({
      openQuickChat: { id: "chat-a" },
    });
  });

  it("reports activation failure without returning success-shaped state", async () => {
    const send = vi.fn(async () => ({
      version: 2 as const,
      kind: "response" as const,
      requestID: "request",
      success: true as const,
    }));

    await expect(
      activateQuickChat(quickChatState(), "chat-a", send),
    ).rejects.toThrow("did not confirm");
  });

  it("waits for reducer state before resolving a newly created chat route", () => {
    const before = quickChatState();
    const withoutCreatedChat = { ...before, quickChats: [] };
    expect(
      pendingCreatedQuickChatRoute(withoutCreatedChat, "chat-a"),
    ).toBeUndefined();

    const after = appReducer(withoutCreatedChat, {
      type: "envelopeReceived",
      envelope: {
        version: 2,
        kind: "response",
        requestID: "create",
        event: {
          type: "quickChatChanged",
          chat: before.quickChats[0],
        },
      },
    });
    expect(pendingCreatedQuickChatRoute(after, "chat-a")).toEqual({
      kind: "quickChat",
      id: "chat-a",
    });
  });
});
