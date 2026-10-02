import { type AliasMap, expandAliases } from "../shell/aliases";
import { type Command, getCommand } from "../shell/tokenize";

export interface LineRead {
  /** The buffer up to the cursor. */
  text: string;
  command: Command;
}

/**
 * The command the cursor is at the end of, with aliases expanded; null when there is nothing to
 * complete: the cursor inside a word, a blank line, a comment, right after an operator, …
 */
export function readLine(buffer: string, cursor: number, aliases: AliasMap): LineRead | null {
  if (buffer.charAt(cursor).trim() !== "") {
    return null;
  }
  const text = buffer.slice(0, cursor);
  const found = text.trim() === "" ? null : getCommand(text);
  if (found === null) {
    return null;
  }
  return { text, command: found.redirectTarget ? found : expandAliases(found, aliases) };
}

export interface EditKind {
  /** One token fewer, the last one unchanged: the user deleted back into the previous word. */
  backspacedIntoPreviousToken: boolean;
  /** More than one character changed: a paste, a history recall, … */
  largeChange: boolean;
}

export function classifyEdit(previous: LineRead | null, next: LineRead): EditKind {
  const oldTokens = previous?.command.tokens ?? [];
  const newTokens = next.command.tokens;
  const before = previous?.text ?? "";
  const typed =
    (next.text.startsWith(before) || before.startsWith(next.text)) && Math.abs(next.text.length - before.length) < 2;
  return {
    backspacedIntoPreviousToken:
      newTokens.length < oldTokens.length && oldTokens[newTokens.length - 1]?.text === newTokens.at(-1)?.text,
    largeChange: !typed,
  };
}
