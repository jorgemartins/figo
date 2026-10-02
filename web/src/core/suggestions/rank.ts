import type { RecencyIndex } from "./recency";
import type { Item } from "./types";

/**
 * Effective priority (engine doc §6.4): the spec's priority (0 and unset both mean 50, as
 * upstream), clamped to 0–100, plus a recency boost. A recently picked suggestion with an ordinary
 * priority (50–75) moves to just above 75, newer above older.
 */
export function rankItems(items: readonly Item[], rootCommand: string, recency: RecencyIndex | null): Item[] {
  return items.map((item) => {
    const name = item.names[0] ?? "";
    const used = recency && name !== "../" ? recency.lastUsed(rootCommand, name) : undefined;
    const boost = used ? used / 1e13 : 0;
    let priority = item.priority || 50;
    if (item.type !== "auto-execute") {
      priority = Math.max(0, Math.min(100, priority));
    }
    priority = used && priority >= 50 && priority <= 75 ? 75 + boost : priority + boost;
    return { ...item, rank: priority };
  });
}

/** Stable sort by effective priority, so ties keep collection order. */
export function sortByRank(items: Item[]): Item[] {
  return items.sort((a, b) => (b.rank ?? 0) - (a.rank ?? 0));
}
