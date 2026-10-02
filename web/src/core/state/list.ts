import type { Settings } from "../../bridge/contract";
import type { ParseResult } from "../parser/parse";
import { SETTING, booleanSetting, stringSetting } from "../settings";
import { type GeneratorResults, collectSuggestions } from "../suggestions/collect";
import { dedupe, filterItems } from "../suggestions/filter";
import { rankItems, sortByRank } from "../suggestions/rank";
import type { RecencyIndex } from "../suggestions/recency";
import type { Item, RankedItem } from "../suggestions/types";

export interface ListOptions {
  settings: Settings;
  recency: RecencyIndex;
  fuzzy: boolean;
  /** History mode (ctrl+r) is on. */
  historyMode: boolean;
  /** History entries continuing the line, for history mode and `beta.history.mode`. */
  history: () => Item[];
}

function candidates(result: ParseResult, runs: readonly GeneratorResults[], options: ListOptions): Item[] {
  const mode = stringSetting(options.settings, SETTING.historyMode);
  if (options.historyMode || mode === "history_only") {
    return options.history();
  }
  const items = collectSuggestions(result, runs);
  if (mode === "show") {
    const known = new Set(items.flatMap((item) => item.names));
    items.push(...options.history().filter((item) => !known.has(item.names[0] ?? "")));
  }
  return items;
}

/** The list for a parse: candidates, ranked (recency), filtered by the typed text, deduplicated. */
export function buildList(result: ParseResult, runs: readonly GeneratorResults[], options: ListOptions): RankedItem[] {
  const { settings } = options;
  const root = result.tokens[result.commandIndex] ?? "";
  const alphabetical = stringSetting(settings, SETTING.sortMethod) === "alphabetical";
  const ranked = sortByRank(rankItems(candidates(result, runs, options), root, alphabetical ? null : options.recency));
  return dedupe(
    filterItems(ranked, result.searchTerm, {
      fuzzy: options.fuzzy,
      suggestCurrentToken:
        result.currentArg?.suggestCurrentToken ?? booleanSetting(settings, SETTING.alwaysSuggestCurrentToken),
      hideAutoExecute:
        booleanSetting(settings, SETTING.hideAutoExecuteSuggestion) || booleanSetting(settings, SETTING.onlyShowOnTab),
      executeAfterSpace: booleanSetting(settings, SETTING.immediatelyExecuteAfterSpace),
      runDangerous: booleanSetting(settings, SETTING.immediatelyRunDangerousCommands),
    }),
  );
}
