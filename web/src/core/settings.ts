import type { Settings } from "../bridge/contract";

/** Setting keys the core reads; names are upstream's so existing settings files keep working. */
export const SETTING = {
  disable: "autocomplete.disable",
  fuzzySearch: "autocomplete.fuzzySearch",
  sortMethod: "autocomplete.sortMethod",
  preferVerboseSuggestions: "autocomplete.preferVerboseSuggestions",
  insertSpaceAutomatically: "autocomplete.insertSpaceAutomatically",
  immediatelyExecuteAfterSpace: "autocomplete.immediatelyExecuteAfterSpace",
  immediatelyRunDangerousCommands: "autocomplete.immediatelyRunDangerousCommands",
  hideAutoExecuteSuggestion: "autocomplete.hideAutoExecuteSuggestion",
  alwaysSuggestCurrentToken: "autocomplete.alwaysSuggestCurrentToken",
  onlyShowOnTab: "autocomplete.onlyShowOnTab",
  scrollWrapAround: "autocomplete.scrollWrapAround",
  navigateToHistory: "autocomplete.navigateToHistory",
  firstTokenCompletion: "autocomplete.firstTokenCompletion",
  disableForCommands: "autocomplete.disableForCommands",
  scriptTimeout: "autocomplete.scriptTimeout",
  alwaysShowDescription: "autocomplete.alwaysShowDescription",
  historyDisableLoading: "autocomplete.history.disableLoading",
  historyMode: "beta.history.mode",
  historyCustomCommand: "beta.history.customCommand",
  historyAllShells: "beta.history.allShells",
  autoCache: "beta.autocomplete.auto-cache",
  keybindingPrefix: "autocomplete.keybindings.",
} as const;

export function booleanSetting(settings: Settings, key: string, fallback = false): boolean {
  const value = settings[key];
  return typeof value === "boolean" ? value : fallback;
}

export function numberSetting(settings: Settings, key: string, fallback: number): number {
  const value = settings[key];
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

export function stringSetting(settings: Settings, key: string): string | undefined {
  const value = settings[key];
  return typeof value === "string" && value !== "" ? value : undefined;
}

export function stringListSetting(settings: Settings, key: string): string[] {
  const value = settings[key];
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
}
