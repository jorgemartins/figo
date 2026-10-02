/**
 * What accepting a suggestion types into the shell (UI doc §4): the text, minus what the user
 * already typed, as backspaces, text and cursor-left escapes.
 *
 * Only a spec may give an entry keystrokes of its own (a backspace or final newline in its insert
 * value, `{cursor}`). Names, file names, generator values and history are typed as text, and an
 * insertion that would type any other control character is refused.
 */
import { type OpenQuote, type Token, isFish, quoteAt, sourceStartOf } from "../shell/tokenize";
import { fuzzyMatch } from "../suggestions/fuzzy";
import { queryTermFor } from "../suggestions/queryTerm";
import type { Item } from "../suggestions/types";
import { codePointLength, hasControlCharacters } from "../utils";

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
  /** The session's shell (`zsh`, `bash`, `fish`): fish quotes differently. */
  shell?: string;
}

const CURSOR = "{cursor}";
/**
 * Where `{cursor}` was in insertion text. A control character, so no name can contain it (names
 * with control characters are dropped) and a literal `{cursor}` in a file name stays text.
 */
const CURSOR_MARK = "\u0000";
const CURSOR_LEFT = "\x1b[D";
// Upstream quotes only for `\ ? * ' " # | < > ( ) [ ] ! &`; `$`, backtick and `;` would also be
// interpreted by the shell, so they are quoted too, and so are braces (`{a,b}` expands).
const NEEDS_QUOTING = "\\?*'\"#|<>()[]!&$`;{}";
/**
 * What a backslash must protect outside quotes, in zsh, bash and fish alike; `~`, `=` (zsh's
 * `=command`) and `%` (fish's `%self`) only matter at the start of a word.
 */
const SPECIAL = /[ \\?*'"#|<>()[\]!&$`;{}]|^[~=%]/g;

/** Whether `item` was written by a spec, so its insert value may carry keystrokes and `{cursor}`. */
function isSpecDefined(item: Item): boolean {
  return item.generator === undefined && item.type !== "history";
}

/**
 * `text` in single quotes. zsh and bash take everything literally there, so a quote is written
 * `'"'"'`; fish reads `\'` and `\\` as escapes even inside single quotes, so both are escaped.
 */
function singleQuoted(text: string, fish: boolean): string {
  return fish ? `'${text.replace(/[\\']/g, "\\$&")}'` : `'${text.replace(/'/g, `'"'"'`)}'`;
}

export function escapeInsertion(text: string, isFolder: boolean, fish = false): string {
  const expandsAtStart = /^[~=%]/.test(text);
  if (!expandsAtStart && ![...NEEDS_QUOTING].some((char) => text.includes(char))) {
    return text.replace(/ /g, "\\ ");
  }
  return isFolder && text.endsWith("/") ? `${singleQuoted(text.slice(0, -1), fish)}/` : singleQuoted(text, fish);
}

/** Backslash-escapes `text`, so it stays correct when more of the word is typed after it. */
function escapeWord(text: string): string {
  return text.replace(SPECIAL, "\\$&");
}

/**
 * `text` typed inside a quote the user opened earlier in the word (`cat "src/My F`), escaped for
 * that quote. A complete entry closes the quote, except a folder, which the user may continue.
 * Where the quote cannot hold the text (`!` in zsh's and bash's double quotes, anything in `$'…'`),
 * the quote is closed first and the text escaped as outside quotes.
 *
 * Inside single quotes zsh and bash write a quote as `'\''`; fish escapes `\` and `'`. Inside
 * double quotes `$`, `"` and `\` are escaped, and the backtick too except in fish, which keeps
 * the backslash before it.
 */
function escapeInsideQuote(text: string, quote: OpenQuote, complete: boolean, isFolder: boolean, fish: boolean): string {
  const close = complete && !isFolder;
  if (quote === "'") {
    const escaped = fish ? text.replace(/[\\']/g, "\\$&") : text.replace(/'/g, `'\\''`);
    return `${escaped}${close ? "'" : ""}`;
  }
  if (quote === '"' && (fish || !text.includes("!"))) {
    const escaped = text.replace(fish ? /[$"\\]/g : /[$`"\\]/g, "\\$&");
    return `${escaped}${close ? '"' : ""}`;
  }
  const closer = quote === '"' ? '"' : "'";
  return closer + (complete ? escapeInsertion(text, isFolder, fish) : escapeWord(text));
}

/** The part of the buffer the insertion replaces, and the quote it is inside of if that quote stays. */
interface Replaced {
  /** What the user typed for the query, exactly as it is in the buffer (quotes and escapes included). */
  typed: string;
  quote: OpenQuote | null;
}

function replaced(item: Item, context: InsertionContext): Replaced {
  const query = queryTermFor(item, context.searchTerm);
  const { token, buffer } = context;
  if (token === null) {
    return { typed: query, quote: null };
  }
  if (!token.text.endsWith(query)) {
    return { typed: buffer.slice(Math.max(token.start, token.end - query.length), token.end), quote: null };
  }
  let innerIndex = token.text.length - query.length;
  if (item.type === "shortcut" && context.searchTerm.startsWith("?") && innerIndex > 0) {
    innerIndex -= 1; // the `?` that selects shortcuts goes too
  }
  // History entries carry their own quoting: replace from the first character inside the quotes.
  const start =
    item.type === "history" ? (token.offsets[innerIndex] ?? token.end) : sourceStartOf(token, innerIndex, buffer);
  // An opening quote right before the query is replaced with it; one further back stays open.
  return { typed: buffer.slice(start, token.end), quote: quoteAt(buffer, token.start, start, isFish(context.shell ?? "")) };
}

/**
 * How `name` is typed for `item` at the cursor: escaped for the quote it is inside of, or for no
 * quote. `complete` is false for Tab's shared prefix, which more text will follow.
 */
export function escapedName(item: Item, name: string, context: InsertionContext, complete: boolean): string {
  const isFolder = item.type === "folder";
  const isPath = isFolder || item.type === "file";
  let text = name;
  // A file named `-rf` typed as a word of its own would be an option.
  if (isPath && text.startsWith("-") && queryTermFor(item, context.searchTerm) === context.searchTerm) {
    text = `./${text}`;
  }
  const fish = isFish(context.shell ?? "");
  const { quote } = replaced(item, context);
  if (quote !== null) {
    return escapeInsideQuote(text, quote, complete, isFolder, fish);
  }
  return complete ? escapeInsertion(text, isFolder, fish) : escapeWord(text);
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
    // `{cursor}` is honoured only where a spec wrote it; elsewhere it is text like any other.
    return isSpecDefined(item) ? item.insertValue.replace(CURSOR, CURSOR_MARK) : item.insertValue;
  }
  const query = queryTermFor(item, context.searchTerm);
  const name = escapedName(item, matchingName(item, query, context.fuzzy, context.preferVerbose) ?? "", context, true);
  return item.separatorToAdd ? `${name}${item.separatorToAdd}${CURSOR_MARK}` : name;
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
 * Whether `text` (without its final newline) can be typed: no control characters, except the
 * backspaces a spec may write into an insert value.
 */
function isTypable(item: Item, text: string): boolean {
  return !hasControlCharacters(isSpecDefined(item) ? text.replace(/\x08/g, "") : text);
}

/**
 * The bytes for `shell.insert`: backspaces over what was typed, the text, and a cursor-left for
 * every character after `{cursor}`. Typed text that the insertion starts with is kept rather than
 * retyped (`Si` + `Sites/` sends `tes/`). Auto-execute entries only send their newline. Null when
 * the text holds anything that is not text (control characters other than a spec's backspaces and
 * one final newline): such an insertion is never sent.
 */
export function insertionBytes(item: Item, text: string, context: InsertionContext, full: boolean): string | null {
  let value = text;
  let moveLeft = "";
  const at = value.indexOf(CURSOR_MARK);
  if (at !== -1) {
    value = value.slice(0, at) + value.slice(at + CURSOR_MARK.length);
    moveLeft = CURSOR_LEFT.repeat(codePointLength(value.slice(at)));
  }
  const executes = value.endsWith("\n");
  if (!isTypable(item, executes ? value.slice(0, -1) : value)) {
    return null;
  }
  if (executes) {
    moveLeft = ""; // after the newline the cursor would move at the next prompt
  }
  // Upstream also deleted nothing for `special` (help template) entries, so `se` + `send` became
  // `sesend`; those are treated like any other entry here.
  if (full && item.type === "auto-execute") {
    return value + moveLeft;
  }
  const { typed } = replaced(item, context);
  if (value.startsWith(typed)) {
    return value.slice(typed.length) + moveLeft;
  }
  return "\b".repeat(codePointLength(typed)) + value + moveLeft;
}
