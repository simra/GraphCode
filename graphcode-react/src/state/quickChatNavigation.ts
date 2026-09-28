import { openQuickChatCommand } from "../protocol/commands";
import type { DaemonWireEnvelope } from "../protocol/domain";
import type { AppState } from "./graphState";
import type { NavigationRoute } from "./navigationHistory";

export interface QuickChatActivation {
  activated: true;
  envelope?: DaemonWireEnvelope;
}

export async function activateQuickChat(
  state: AppState,
  id: string,
  send: (command: object) => Promise<DaemonWireEnvelope>,
): Promise<QuickChatActivation> {
  if (!state.quickChats.some((chat) => chat.id === id)) {
    throw new Error("Quick Chat is no longer available");
  }
  if (state.quickChatsSelected && state.selectedQuickChatId === id) {
    return { activated: true };
  }

  const envelope = await send(openQuickChatCommand(id));
  if (
    envelope.kind !== "response" ||
    envelope.event?.type !== "quickChatChanged" ||
    envelope.event.chat.id !== id
  ) {
    throw new Error("Quick Chat activation did not confirm the requested chat");
  }
  return { activated: true, envelope };
}

export function pendingCreatedQuickChatRoute(
  state: AppState,
  id: string | undefined,
): NavigationRoute | undefined {
  return id && state.quickChats.some((chat) => chat.id === id)
    ? { kind: "quickChat", id }
    : undefined;
}
