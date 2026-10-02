import type { Item } from "./types";

/** The part of the search term an entry is matched against (engine doc §5.6). */
export function queryTermFor(item: Item, searchTerm: string): string {
  if (item.queryTerm) {
    return item.queryTerm(searchTerm);
  }
  const getQueryTerm = item.generator?.getQueryTerm;
  if (typeof getQueryTerm === "string") {
    const at = searchTerm.lastIndexOf(getQueryTerm);
    return at === -1 ? searchTerm : searchTerm.slice(at + getQueryTerm.length);
  }
  if (typeof getQueryTerm === "function") {
    try {
      return getQueryTerm(searchTerm);
    } catch {
      // Fall back to the whole term.
    }
  }
  if (item.type === "shortcut" && searchTerm.startsWith("?")) {
    return searchTerm.slice(1);
  }
  return searchTerm;
}
