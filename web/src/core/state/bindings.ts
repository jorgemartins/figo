import type { Settings } from "../../bridge/contract";
import type { ActionId } from "../contract";
import { SETTING } from "../settings";

/** The web app's default keymap (UI doc §3.2); figterm's older built-in table is not used. */
export const DEFAULT_BINDINGS: Readonly<Record<string, ActionId>> = {
  enter: "insertSelected",
  tab: "insertCommonPrefix",
  esc: "hideAutocomplete",
  "shift+tab": "navigateUp",
  up: "navigateUp",
  "control+p": "navigateUp",
  down: "navigateDown",
  "control+n": "navigateDown",
  "control+k": "toggleDescription",
  "control+r": "toggleHistoryMode",
};

const MODIFIER_ALIASES: Record<string, string> = {
  ctrl: "control",
  control: "control",
  alt: "option",
  opt: "option",
  option: "option",
  meta: "command",
  cmd: "command",
  command: "command",
  shift: "shift",
};
const MODIFIER_ORDER = ["control", "option", "shift", "command"];
const KEY_ALIASES: Record<string, string> = {
  arrowup: "up",
  arrowdown: "down",
  arrowleft: "left",
  arrowright: "right",
  escape: "esc",
  return: "enter",
};

/**
 * One spelling per key, so a user's `ctrl+k` overrides the default `control+k` instead of sitting
 * next to it.
 */
export function normalizeBinding(binding: string): string {
  const parts = binding
    .toLowerCase()
    .split("+")
    .filter((part) => part !== "");
  const key = parts.pop() ?? "";
  const modifiers = [...new Set(parts.map((part) => MODIFIER_ALIASES[part] ?? part))].sort(
    (a, b) => MODIFIER_ORDER.indexOf(a) - MODIFIER_ORDER.indexOf(b),
  );
  return [...modifiers, KEY_ALIASES[key] ?? key].join("+");
}

/** Defaults merged with `autocomplete.keybindings.<key>` settings; `ignore` unbinds a key. */
export function effectiveBindings(settings: Settings): Record<string, string> {
  const bindings: Record<string, string> = { ...DEFAULT_BINDINGS };
  for (const [key, value] of Object.entries(settings)) {
    if (key.startsWith(SETTING.keybindingPrefix) && typeof value === "string") {
      bindings[normalizeBinding(key.slice(SETTING.keybindingPrefix.length))] = value;
    }
  }
  return bindings;
}
