import type { Settings } from "../bridge/contract";

const KEYBINDING_PREFIX = "autocomplete.keybindings.";
const DESCRIPTION_ACTIONS = new Set(["toggleDescription", "showDescription", "hideDescription"]);
/** The default binding of toggleDescription, which the settings never list. */
const DEFAULT_KEY = "control+k";

const MODIFIER_GLYPHS: Record<string, string> = {
  cmd: "⌘",
  command: "⌘",
  meta: "⌘",
  control: "⌃",
  ctrl: "⌃",
  shift: "⇧",
  option: "⌥",
  opt: "⌥",
};

/** `control+k` → `⌃k`. Unknown tokens (including `alt`, as upstream) are kept as written. */
export function formatKey(binding: string): string {
  return binding
    .split("+")
    .map((token) => MODIFIER_GLYPHS[token] ?? token)
    .join("");
}

/**
 * The text of the badge that tells the user how to open the side panel: the first configured key
 * bound to a description action, else the default `⌃k`. Returns null when the user unbound the
 * default key without binding another, since advertising a dead key would be wrong (upstream
 * keeps showing `⌃k` in that case).
 */
export function descriptionHint(settings: Settings): string | null {
  for (const [key, value] of Object.entries(settings)) {
    if (key.startsWith(KEYBINDING_PREFIX) && typeof value === "string" && DESCRIPTION_ACTIONS.has(value)) {
      return formatKey(key.slice(KEYBINDING_PREFIX.length));
    }
  }
  const defaultOverride = settings[KEYBINDING_PREFIX + DEFAULT_KEY];
  if (defaultOverride !== undefined && defaultOverride !== "toggleDescription") {
    return null;
  }
  return formatKey(DEFAULT_KEY);
}
