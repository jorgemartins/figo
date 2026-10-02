import type { NativeBridge, NativeEvents, NativeRequests } from "./contract";

interface FigoMessageHandler {
  /** WKScriptMessageHandlerWithReply: resolves with the native reply, rejects with its error text. */
  postMessage(message: { method: string; params: unknown }): Promise<unknown>;
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: { figo?: FigoMessageHandler } };
    /** Called by the app (through evaluateJavaScript) to deliver an event. */
    __figoReceive?: (event: string, payload: unknown) => void;
  }
}

/** True when the page is running inside the Figo app rather than a plain browser. */
export function hasNativeHost(): boolean {
  return typeof window !== "undefined" && window.webkit?.messageHandlers?.figo !== undefined;
}

type Listener = (payload: never) => void;

/** The bridge to the Figo app. Only usable when `hasNativeHost()` is true. */
export function createNativeBridge(): NativeBridge {
  const handler = window.webkit?.messageHandlers?.figo;
  if (!handler) {
    throw new Error("Not running inside the Figo app");
  }

  const listeners = new Map<string, Set<Listener>>();

  window.__figoReceive = (event, payload) => {
    for (const listener of listeners.get(event) ?? []) {
      try {
        (listener as (payload: unknown) => void)(payload);
      } catch (error) {
        console.error(`Listener for "${event}" failed`, error);
      }
    }
  };

  return {
    async call<Method extends keyof NativeRequests>(method: Method, params: NativeRequests[Method]["params"]) {
      try {
        return (await handler.postMessage({ method, params })) as NativeRequests[Method]["result"];
      } catch (error) {
        throw error instanceof Error ? error : new Error(String(error));
      }
    },

    on<Event extends keyof NativeEvents>(event: Event, listener: (payload: NativeEvents[Event]) => void) {
      let set = listeners.get(event);
      if (!set) {
        set = new Set();
        listeners.set(event, set);
      }
      set.add(listener as Listener);
      return () => {
        set.delete(listener as Listener);
      };
    },
  };
}
