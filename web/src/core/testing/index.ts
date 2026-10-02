import type { Core } from "../contract";

export { FakeBridge, type ProcessMatcher, type ProcessReply, type RecordedCall } from "./fakeBridge";
export { SPECS_DIR, diskSpecs } from "./specs";

/**
 * Resolves once the core has no parse or generator in flight. Pending timers (generator
 * debounce, the loading delay) count as in flight, so with fake timers advance them first.
 */
export async function whenIdle(core: Core): Promise<void> {
  const idle = (core as Core & { whenIdle?: () => Promise<void> }).whenIdle;
  if (typeof idle !== "function") {
    throw new Error("whenIdle needs the core from createCore");
  }
  // Events can start work in a microtask; let that happen before asking.
  for (let i = 0; i < 3; i += 1) {
    await Promise.resolve();
    await idle.call(core);
  }
}

/** The visible suggestion names, as the popup would show them (`displayName` or names joined). */
export function visibleNames(core: Core): string[] {
  const state = core.getState();
  if (!state.visible) {
    return [];
  }
  return state.suggestions.map((suggestion) => suggestion.displayName ?? suggestion.names.join(", "));
}
