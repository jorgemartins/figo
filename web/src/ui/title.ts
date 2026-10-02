import type { ArgumentHint, CoreState, Suggestion } from "../core/contract";

export type SegmentKind = "text" | "match" | "prefix";

export interface Segment {
  kind: SegmentKind;
  text: string;
}

/**
 * The common prefix to underline, derived from the selected suggestion. Upstream underlines it in
 * every row whose name starts with it, not only in the selected one, so it is kept as text.
 */
export interface PrefixUnderline {
  /** Lowercased text from the start of the name to the end of the underline. */
  head: string;
  start: number;
  end: number;
}

/** The names a row displays: `displayName` alone when present, otherwise every name. */
export function displayedNames(suggestion: Suggestion): string[] {
  return suggestion.displayName !== undefined && suggestion.displayName !== ""
    ? [suggestion.displayName]
    : suggestion.names;
}

export function prefixUnderline(state: Pick<CoreState, "suggestions" | "selectedIndex" | "commonPrefix">): PrefixUnderline | null {
  const selected = state.suggestions[state.selectedIndex];
  const range = state.commonPrefix;
  const name = selected?.names[0];
  if (!selected || !range || name === undefined) {
    return null;
  }
  const [start, end] = range;
  if (start < 0 || end <= start || end > name.length) {
    return null;
  }
  const head = name.slice(0, end).toLowerCase();
  // Upstream never underlines a lone "-": every option shares it, so it says nothing.
  if (head === "-") {
    return null;
  }
  return { head, start, end };
}

function matchRangesFor(suggestion: Suggestion, names: string[], index: number): Array<[number, number]> {
  const { nameIndex, ranges } = suggestion.match;
  if (index === nameIndex) {
    return ranges;
  }
  // The core reports matches for one name only. In prefix mode upstream highlights the typed
  // prefix in every name that starts with it (`install, i` for "i"), so mirror a pure prefix match
  // onto the other names.
  const only = ranges.length === 1 ? ranges[0] : undefined;
  const matchedName = names[nameIndex];
  if (!only || only[0] !== 0 || matchedName === undefined) {
    return [];
  }
  const typed = matchedName.slice(0, only[1]).toLowerCase();
  const name = names[index] ?? "";
  return typed !== "" && name.toLowerCase().startsWith(typed) ? [[0, typed.length]] : [];
}

/** Splits one name into plain, matched and underlined runs. A matched character is never underlined. */
export function nameSegments(name: string, matches: Array<[number, number]>, underline: PrefixUnderline | null): Segment[] {
  const kinds: SegmentKind[] = new Array<SegmentKind>(name.length).fill("text");
  if (underline && name.toLowerCase().startsWith(underline.head)) {
    for (let i = underline.start; i < underline.end && i < name.length; i += 1) {
      kinds[i] = "prefix";
    }
  }
  for (const [start, end] of matches) {
    for (let i = Math.max(0, start); i < end && i < name.length; i += 1) {
      kinds[i] = "match";
    }
  }

  const segments: Segment[] = [];
  for (let i = 0; i < name.length; i += 1) {
    const kind = kinds[i] ?? "text";
    const last = segments[segments.length - 1];
    if (last && last.kind === kind) {
      last.text += name[i];
    } else {
      segments.push({ kind, text: name[i] ?? "" });
    }
  }
  return segments;
}

/** Segments for every displayed name of a row, in order; the caller joins them with ", ". */
export function titleSegments(suggestion: Suggestion, underline: PrefixUnderline | null): Segment[][] {
  const names = displayedNames(suggestion);
  return names.map((name, index) => nameSegments(name, matchRangesFor(suggestion, names, index), underline));
}

/**
 * The dimmed argument list after the names: `[optional]`, `<required> ` (the trailing space is
 * upstream's) and `name...` for variadic ones, joined by spaces. Empty when there is nothing to show.
 */
export function argumentText(args: ArgumentHint[] | undefined): string {
  return (args ?? [])
    .filter((arg) => arg.name)
    .map((arg) => {
      const base = arg.isVariadic ? `${arg.name}...` : arg.name;
      return arg.isOptional ? `[${base}]` : `<${base}> `;
    })
    .join(" ");
}
