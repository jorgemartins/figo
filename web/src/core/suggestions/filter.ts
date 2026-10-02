/**
 * Narrows the ranked candidates to what the typed text matches (engine doc §6.6–6.9): exact name
 * matches first (with an auto-execute twin on top), then prefix or fuzzy matches by score.
 */
import { fuzzyMatch, indexesToRanges } from "./fuzzy";
import { queryTermFor } from "./queryTerm";
import type { Item, MatchInfo, RankedItem } from "./types";

export interface FilterOptions {
  fuzzy: boolean;
  /** The argument's `suggestCurrentToken`, or `autocomplete.alwaysSuggestCurrentToken`. */
  suggestCurrentToken: boolean;
  /** `autocomplete.hideAutoExecuteSuggestion` or `autocomplete.onlyShowOnTab`. */
  hideAutoExecute: boolean;
  /** `autocomplete.immediatelyExecuteAfterSpace`. */
  executeAfterSpace: boolean;
  /** `autocomplete.immediatelyRunDangerousCommands`. */
  runDangerous: boolean;
}

const NO_MATCH: MatchInfo = { nameIndex: 0, ranges: [] };
const CARROT = "fig://icon?type=carrot";

interface ScoredMatch {
  score: number;
  match: MatchInfo;
}

function prefixScore(name: string, query: string): number | null {
  if (name === query) {
    return 0;
  }
  const lowerName = name.toLowerCase();
  const lowerQuery = query.toLowerCase();
  if (lowerName === lowerQuery) {
    return -1;
  }
  if (name.startsWith(query)) {
    return -2;
  }
  return lowerName.startsWith(lowerQuery) ? -3 : null;
}

function prefixRanges(query: string): Array<[number, number]> {
  return query === "" ? [] : [[0, query.length]];
}

/**
 * Best match of `query` over `targets` (engine doc §6.6). In fuzzy mode a prefix match still
 * wins: its score is scaled into (-1, 0], above every fuzzy score (integers ≤ 0, mostly ≤ -1).
 */
function partialMatch(
  targets: readonly string[],
  query: string,
  fuzzy: boolean,
  displayName: boolean,
): ScoredMatch | null {
  let prefix: { score: number; index: number } | null = null;
  for (const [index, target] of targets.entries()) {
    const score = prefixScore(target, query);
    if (score !== null && (prefix === null || score > prefix.score)) {
      prefix = { score, index };
    }
  }
  if (prefix !== null) {
    const match = { nameIndex: displayName ? 0 : prefix.index, ranges: prefixRanges(query) };
    return { score: fuzzy ? prefix.score / 10 : prefix.score, match };
  }
  if (!fuzzy) {
    return null;
  }
  let best: { score: number; index: number; indexes: number[] } | null = null;
  for (const [index, target] of targets.entries()) {
    const found = fuzzyMatch(query, target);
    if (found !== null && (best === null || found.score > best.score)) {
      best = { score: found.score, index, indexes: found.indexes };
    }
  }
  if (best === null) {
    return null;
  }
  return {
    score: best.score,
    match: { nameIndex: displayName ? 0 : best.index, ranges: indexesToRanges(best.indexes) },
  };
}

/** Highlight for an entry shown by name or by its displayName. */
function highlight(item: Item, query: string, nameIndex: number, fuzzy: boolean): MatchInfo {
  if (query === "") {
    return NO_MATCH;
  }
  if (item.displayName === undefined) {
    return { nameIndex, ranges: prefixRanges(query) };
  }
  return partialMatch([item.displayName], query, fuzzy, true)?.match ?? NO_MATCH;
}

function autoExecuteTwin(item: Item, exactName: string): RankedItem {
  const isFolder = item.type === "folder";
  return {
    ...item,
    type: "auto-execute",
    originalType: item.type,
    icon: CARROT,
    names: isFolder ? [exactName.slice(0, -1)] : item.names,
    displayName: isFolder ? undefined : item.displayName,
    description: isFolder ? "folder" : item.description,
    insertValue: "\n",
    match: NO_MATCH,
  };
}

function special(name: string, description: string, originalType?: Item["originalType"]): RankedItem {
  return { type: "auto-execute", names: [name], insertValue: "\n", description, originalType, match: NO_MATCH };
}

export function filterItems(items: readonly Item[], searchTerm: string, options: FilterOptions): RankedItem[] {
  if (searchTerm === "") {
    const visible: RankedItem[] = items.filter((item) => !item.hidden).map((item) => ({ ...item, match: NO_MATCH }));
    if (options.executeAfterSpace && visible.length > 0 && !options.hideAutoExecute) {
      visible.unshift(special("↪", "Immediately execute"));
    }
    return visible;
  }

  const exact: RankedItem[] = [];
  const exactFolders: RankedItem[] = [];
  const partial: Array<{ item: RankedItem; score: number }> = [];
  let twinAdded = false;

  for (const item of items) {
    const query = queryTermFor(item, searchTerm);
    const key = (item.type === "folder" ? `${query}/` : query).toLowerCase();
    const exactIndex = item.names.findIndex((name) => name.toLowerCase() === key);
    if (exactIndex !== -1) {
      const exactName = item.names[exactIndex] ?? "";
      const added: RankedItem[] = [{ ...item, match: highlight(item, query, exactIndex, options.fuzzy) }];
      const firstName = item.names[0];
      const firstArg = item.args?.[0];
      const canExecute =
        (!firstName || !item.insertValue || firstName === item.insertValue) &&
        (!item.isDangerous || options.runDangerous) &&
        (!firstArg || Boolean(firstArg.isOptional));
      if (canExecute && !options.hideAutoExecute && !twinAdded) {
        added.unshift(autoExecuteTwin(item, exactName));
        twinAdded = true;
      }
      (item.type === "folder" ? exactFolders : exact).push(...added);
    } else if (!item.hidden) {
      const match = partialMatch(item.names, query, options.fuzzy, false);
      if (match !== null) {
        const shown =
          item.displayName === undefined ? match.match : highlight(item, query, match.match.nameIndex, options.fuzzy);
        partial.push({ item: { ...item, match: shown }, score: match.score });
      }
    }
    // Upstream also matches the display name, even for hidden or exact entries, which can list one twice.
    if (item.displayName !== undefined) {
      const match = partialMatch([item.displayName], query, options.fuzzy, true);
      if (match !== null) {
        partial.push({ item: { ...item, match: match.match }, score: match.score });
      }
    }
  }

  partial.sort((a, b) => (a.score !== b.score ? b.score - a.score : (b.item.rank ?? 0) - (a.item.rank ?? 0)));
  let result: RankedItem[] = [...exact, ...exactFolders, ...partial.map((entry) => entry.item)];

  if (result.length > 0 && !twinAdded && !options.hideAutoExecute) {
    if (searchTerm === "." || (searchTerm.endsWith("/") && result.some((item) => item.templateType === "folders"))) {
      result = [special(searchTerm === "." ? "." : "↪", "Enter the current directory", "folder"), ...result];
    } else if (options.suggestCurrentToken) {
      result = [special(searchTerm, "Enter the current argument"), ...result];
    }
  }
  return result;
}

function sameList<T>(a: readonly T[] | undefined, b: readonly T[] | undefined): boolean {
  if (a === b) {
    return true;
  }
  if (a === undefined || b === undefined || a.length !== b.length) {
    return false;
  }
  return a.every((value, i) => value === b[i]);
}

/** Drops repeats (same names, insert value, display name and arguments); only for short lists, as upstream. */
export function dedupe(items: RankedItem[]): RankedItem[] {
  if (items.length === 0 || items.length > 50) {
    return items;
  }
  const kept: RankedItem[] = [];
  for (const item of items) {
    const duplicate = kept.some(
      (other) =>
        sameList(other.names, item.names) &&
        other.insertValue === item.insertValue &&
        other.displayName === item.displayName &&
        sameList(other.args, item.args),
    );
    if (!duplicate) {
      kept.push(item);
    }
  }
  return kept;
}
