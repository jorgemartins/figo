import type { NativeRequests, SessionId, Settings, ShellContext } from "../../bridge/contract";
import type { CoreState } from "../contract";
import { commonPrefixRange } from "../insertion/commonPrefix";
import type { ParseResult } from "../parser/parse";
import { SETTING, booleanSetting, stringSetting } from "../settings";
import { directoryOfPath } from "../shell/expand";
import { presentItem } from "../suggestions/present";
import type { RankedItem } from "../suggestions/types";
import { effectiveBindings } from "./bindings";
import type { Visibility } from "./visibility";

export interface OutputInput {
  sessionId: SessionId | null;
  context: ShellContext | null;
  settings: Settings;
  visibility: Visibility;
  items: readonly RankedItem[];
  selectedIndex: number;
  /** The parse the shown list was built from. */
  listResult: ParseResult | null;
  /** The latest parse (its argument names the hint when the list is empty). */
  parse: ParseResult | null;
  loading: boolean;
  historyMode: boolean;
  descriptionPopout: boolean;
  scale: number;
  shakeCount: number;
}

export function coreStateOf(input: OutputInput): CoreState {
  const { context, settings, listResult } = input;
  const directory =
    listResult !== null && context !== null
      ? directoryOfPath(listResult.searchTerm, context.cwd, context.home, context.env)
      : null;
  const suggestions = input.items.map((item) => presentItem(item, directory));
  const arg = input.parse?.currentArg;
  // Reported alongside the list too: the footer falls back to it when the selected item has no
  // description of its own (a git branch, say).
  const argument = arg?.name
    ? { name: arg.name, ...(arg.description ? { description: arg.description } : {}) }
    : null;
  const enabled = !booleanSetting(settings, SETTING.disable);
  return {
    sessionId: input.sessionId,
    // "Visible" also needs something to show: a list, the argument hint, or the loading indicator.
    visible:
      enabled && input.visibility === "visible" && (suggestions.length > 0 || argument !== null || input.loading),
    suggestions,
    selectedIndex: suggestions.length > 0 ? Math.min(input.selectedIndex, suggestions.length - 1) : 0,
    commonPrefix: commonPrefixRange(input.items, input.selectedIndex, listResult?.searchTerm ?? ""),
    loading: input.loading,
    argument,
    historyMode: input.historyMode || stringSetting(settings, SETTING.historyMode) === "history_only",
    descriptionPopout: booleanSetting(settings, SETTING.alwaysShowDescription) || input.descriptionPopout,
    scale: input.scale,
    shakeCount: input.shakeCount,
    settings,
  };
}

export type InterceptParams = NativeRequests["shell.setIntercept"]["params"];

/** Which keys the session's wrapper should take (UI doc §3.3). */
export function interceptFor(sessionId: SessionId, state: CoreState, visibility: Visibility): InterceptParams {
  const count = state.suggestions.length;
  const bindings = effectiveBindings(state.settings);
  if (booleanSetting(state.settings, SETTING.onlyShowOnTab) && visibility !== "visible") {
    bindings.tab = "showAutocomplete";
  }
  return {
    sessionId,
    interceptBound: state.visible && count > 0,
    // Nothing is taken right after an insertion, until the shell has echoed it.
    interceptGlobal: count > 0 && visibility !== "hiddenByInsertion",
    bindings,
  };
}
