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
  /**
   * The buffer holds more than the command being completed (`a && b`, `$(…)`, text after the
   * cursor): running it from the list would run all of it, unchecked.
   */
  compoundLine?: boolean;
}

/**
 * Whether running the line now could run something dangerous: the argument being completed, an
 * option given, or an argument already given is marked dangerous (`rm -rf`, `wipe target …`).
 */
function isDangerousLine(result: ParseResult): boolean {
  const given = result.annotations.flatMap((annotation) =>
    annotation.type === "composite" ? annotation.subtokens : [annotation],
  );
  return (
    Boolean(result.currentArg?.isDangerous) ||
    result.passedOptions.some((option) => option.isDangerous === true) ||
    given.some(
      (annotation) =>
        (annotation.type === "subcommand_arg" || annotation.type === "option_arg") && annotation.arg?.isDangerous === true,
    )
  );
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
      dangerousLine: Boolean(options.compoundLine) || isDangerousLine(result),
    }),
  );
}
