/**
 * What accepting a suggestion types into the shell (UI doc §4): the text, minus what the user
 * already typed, as backspaces, text and cursor-left escapes.
 */
import { type Token, sourceStartOf } from "../shell/tokenize";
import { fuzzyMatch } from "../suggestions/fuzzy";
import { queryTermFor } from "../suggestions/queryTerm";
import type { Item } from "../suggestions/types";
import { codePointLength } from "../utils";

export interface InsertionContext {
  /** The parse's search term. */
  searchTerm: string;
  /** The whole edit buffer the list was computed from. */
  buffer: string;
  /** The token being completed, with its position in `buffer`. */
  token: Token | null;
  fuzzy: boolean;
  /** `autocomplete.preferVerboseSuggestions`. */
  preferVerbose: boolean;
  /** `autocomplete.insertSpaceAutomatically`. */
  insertSpace: boolean;
}

const CURSOR = "{cursor}";
const CURSOR_LEFT = "\x1b[D";
// Upstream quotes only for `\ ? * ' " # | < > ( ) [ ] ! &`; `$`, backtick and `;` would also be
// interpreted by the shell, so they are quoted too.
const NEEDS_QUOTING = "\\?*'\"#|<>()[]!&$`;";

export function escapeInsertion(text: string, isFolder: boolean): string {
  if (![...NEEDS_QUOTING].some((char) => text.includes(char))) {
    return text.includes(" ") ? text.replace(/\s/g, "\\ ") : text;
  }
  const quote = (value: string) => `'${value.replace(/'/g, `'"'"'`)}'`;
  return isFolder && text.endsWith("/") ? `${quote(text.slice(0, -1))}/` : quote(text);
}

function longest(names: readonly string[]): string | undefined {
  return names.reduce<string | undefined>(
    (best, name) => (best === undefined || name.length > best.length ? name : best),
    undefined,
  );
}

/** The name to insert: the one that matched the query (the longest, with preferVerbose). */
function matchingName(item: Item, query: string, fuzzy: boolean, preferVerbose: boolean): string | undefined {
  const lowerQuery = query.toLowerCase();
  const matches = item.names.filter((name) =>
    fuzzy ? query === "" || fuzzyMatch(query, name) !== null : name.toLowerCase().startsWith(lowerQuery),
  );
  const candidates = matches.length > 0 ? matches : item.names;
  const verbose = preferVerbose && (item.type === "option" || item.type === "subcommand");
  return verbose ? longest(candidates) : candidates[0];
}

/** The text a full insertion stands for, before trailing space and deletion are worked out. */
export function insertionText(item: Item, context: InsertionContext): string {
  const isFolder = item.type === "folder";
  if (item.insertValue && !isFolder && item.type !== "file") {
    return item.insertValue;
  }
  const query = queryTermFor(item, context.searchTerm);
  const name = matchingName(item, query, context.fuzzy, context.preferVerbose) ?? "";
  return escapeInsertion(item.separatorToAdd ? `${name}${item.separatorToAdd}${CURSOR}` : name, isFolder);
}

/** Full insertion text including the execute newline and the automatic trailing space. */
export function fullInsertionText(item: Item, context: InsertionContext, execute: boolean): string {
  let text = insertionText(item, context);
  if (execute && item.type !== "auto-execute") {
    text += "\n";
  }
  text = text.replace(/\n+$/, "\n");
  if (!text.endsWith("\n") && item.shouldAddSpace && context.insertSpace) {
    text += " ";
  }
  return text;
}

/**
 * What the user typed for the query, exactly as it is in the buffer (quotes and escapes
 * included), so it can be deleted or skipped.
 */
function typedText(item: Item, context: InsertionContext): string {
  const query = queryTermFor(item, context.searchTerm);
  const { token, buffer } = context;
  if (token === null) {
    return query;
  }
  if (!token.text.endsWith(query)) {
    return buffer.slice(Math.max(token.start, token.end - query.length), token.end);
  }
  let innerIndex = token.text.length - query.length;
  if (item.type === "shortcut" && context.searchTerm.startsWith("?") && innerIndex > 0) {
    innerIndex -= 1; // the `?` that selects shortcuts goes too
  }
  // History entries carry their own quoting: replace from the first character inside the quotes.
  const start =
    item.type === "history" ? (token.offsets[innerIndex] ?? token.end) : sourceStartOf(token, innerIndex, buffer);
  return buffer.slice(start, token.end);
}

/**
 * The bytes for `shell.insert`: backspaces over what was typed, the text, and a cursor-left for
 * every character after `{cursor}`. Typed text that the insertion starts with is kept rather than
 * retyped (`Si` + `Sites/` sends `tes/`). Auto-execute entries only send their newline.
 */
export function insertionBytes(item: Item, text: string, context: InsertionContext, full: boolean): string {
  let value = text;
  let moveLeft = "";
  const at = value.indexOf(CURSOR);
  if (at !== -1) {
    value = value.slice(0, at) + value.slice(at + CURSOR.length);
    moveLeft = CURSOR_LEFT.repeat(codePointLength(value.slice(at)));
  }
  // Upstream also deleted nothing for `special` (help template) entries, so `se` + `send` became
  // `sesend`; those are treated like any other entry here.
  if (full && item.type === "auto-execute") {
    return value + moveLeft;
  }
  const typed = typedText(item, context);
  if (value.startsWith(typed)) {
    return value.slice(typed.length) + moveLeft;
  }
  return "\b".repeat(codePointLength(typed)) + value + moveLeft;
}
