/**
 * Tab's "insert the common prefix" (UI doc §4.7), and the matching underline range.
 */
import { queryTermFor } from "../suggestions/queryTerm";
import type { Item } from "../suggestions/types";
import { ensureTrailingSlash, longestCommonPrefix } from "../utils";
import { type InsertionContext, escapedName, insertionText } from "./insert";

export type PrefixOutcome = { kind: "full" } | { kind: "partial"; text: string } | { kind: "none"; reason: string };

function isPath(item: Item): boolean {
  return item.type === "file" || item.type === "folder";
}

/** Same group for prefix purposes: files and folders together, `../` only with itself. */
function sameGroup(a: Item, b: { type: Item["type"]; names: string[] }): boolean {
  if (a.names[0] === "../") {
    return b.names[0] === "../";
  }
  const bIsPath = b.type === "file" || b.type === "folder";
  return (isPath(a) && bIsPath) || a.type === b.type;
}

/** The selected entry's group, seen through an auto-execute twin to what it stands for. */
function groupOf(selected: Item): { type: Item["type"]; names: string[] } | null {
  const type = selected.type === "auto-execute" ? selected.originalType : selected.type;
  if (type === "special" || type === "auto-execute") {
    return null;
  }
  const names =
    selected.type === "auto-execute" && selected.originalType === "folder"
      ? selected.names.map(ensureTrailingSlash)
      : selected.names;
  return { type, names };
}

function sharedPrefix(items: readonly Item[], selected: Item, query: string): string | null {
  const group = groupOf(selected);
  if (group === null) {
    return null;
  }
  const lowerQuery = query.toLowerCase();
  const names = items
    .filter((item) => sameGroup(item, group))
    .map((item) => (item.names[0] ?? "").toLowerCase())
    .filter((name) => name.startsWith(lowerQuery));
  if (names.length < 2) {
    return null;
  }
  return (selected.names[0] ?? "").slice(0, longestCommonPrefix(names).length);
}

export function commonPrefixOutcome(
  items: readonly Item[],
  selectedIndex: number,
  context: InsertionContext,
): PrefixOutcome {
  const selected = items[selectedIndex];
  if (selected === undefined) {
    return { kind: "none", reason: "Nothing selected" };
  }
  if (items.length === 1) {
    return { kind: "full" };
  }
  const group = groupOf(selected);
  if (group === null) {
    return { kind: "none", reason: `No common prefix for ${selected.type ?? "untyped"} entries` };
  }
  const query = queryTermFor(selected, context.searchTerm);
  const lowerQuery = query.toLowerCase();
  const candidates = items.filter(
    (item) => sameGroup(item, group) && (item.names[0] ?? "").toLowerCase().startsWith(lowerQuery),
  );
  if (candidates.length === 1) {
    return selected.type === "auto-execute"
      ? { kind: "none", reason: "Cannot execute through a prefix" }
      : { kind: "full" };
  }
  const shared = sharedPrefix(items, selected, query);
  if (!shared || shared === query) {
    return { kind: "none", reason: "No remaining prefix to insert" };
  }
  if (escapedName(selected, shared, context, true) === insertionText(selected, context)) {
    return selected.type === "auto-execute"
      ? { kind: "none", reason: "Cannot execute through a prefix" }
      : { kind: "full" };
  }
  // Escaped so that it stays correct whatever is typed after it (`Screenshot\ \(`).
  return { kind: "partial", text: escapedName(selected, shared, context, false) };
}

/**
 * The [start, end) part of the selected entry's first name that Tab would add, for underlining.
 */
export function commonPrefixRange(
  items: readonly Item[],
  selectedIndex: number,
  searchTerm: string,
): [number, number] | null {
  const selected = items[selectedIndex];
  if (selected === undefined || items.length < 2) {
    return null;
  }
  const query = queryTermFor(selected, searchTerm);
  const shared = sharedPrefix(items, selected, query);
  if (shared === null || shared === "-" || shared.length <= query.length) {
    return null;
  }
  return [query.length, shared.length];
}
