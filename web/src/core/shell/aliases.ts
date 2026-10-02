import { type Command, type Token, wordsOfSimpleCommand } from "./tokenize";

export type AliasMap = ReadonlyMap<string, string>;

/**
 * Parses the output of the shell's `alias` builtin:
 *   zsh   `ll='ls -l'`            bash `alias ll='ls -l'`            fish `alias ll 'ls -l'`
 * Values are shell-quoted, may contain `'\''` sequences and may span lines.
 */
export function parseAliases(output: string, shell: string): Map<string, string> {
  const fish = shell === "fish" || shell.endsWith("/fish");
  const aliases = new Map<string, string>();
  for (const entry of splitEntries(output, fish)) {
    const line = entry.replace(/^\s*alias\s+(--\s+)?/, "");
    const at = fish ? line.search(/\s/) : indexOutsideQuotes(line, "=");
    if (at <= 0) {
      continue;
    }
    const name = unquote(line.slice(0, at), fish);
    const value = unquote(line.slice(at + 1).replace(/^\s+/, ""), fish);
    if (name) {
      aliases.set(name, value);
    }
  }
  return aliases;
}

/** Splits on newlines that are not inside quotes, so multi-line values stay whole. */
function splitEntries(output: string, fish: boolean): string[] {
  const entries: string[] = [];
  let current = "";
  let quote: string | null = null;
  for (let i = 0; i < output.length; i += 1) {
    const c = output.charAt(i);
    if (c === "\\" && (quote === null || quote === '"' || fish)) {
      current += c + output.charAt(i + 1);
      i += 1;
      continue;
    }
    if (quote === null) {
      if (c === "\n") {
        entries.push(current);
        current = "";
        continue;
      }
      if (c === "'" || c === '"') {
        quote = c;
      }
    } else if (c === quote) {
      quote = null;
    }
    current += c;
  }
  entries.push(current);
  return entries.filter((entry) => entry.trim() !== "");
}

function indexOutsideQuotes(text: string, char: string): number {
  let quote: string | null = null;
  for (let i = 0; i < text.length; i += 1) {
    const c = text.charAt(i);
    if (quote === null && c === "\\") {
      i += 1;
    } else if (quote === null && (c === "'" || c === '"')) {
      quote = c;
    } else if (c === quote) {
      quote = null;
    } else if (quote === null && c === char) {
      return i;
    }
  }
  return -1;
}

const ANSI_ESCAPES: Record<string, string> = {
  n: "\n",
  t: "\t",
  r: "\r",
  e: "\x1b",
  a: "\x07",
  "\\": "\\",
  "'": "'",
  '"': '"',
};

/** Removes one level of shell quoting. Fish allows `\'` and `\\` inside single quotes. */
export function unquote(text: string, fish = false): string {
  let out = "";
  let i = 0;
  while (i < text.length) {
    const c = text.charAt(i);
    if (c === "'") {
      i += 1;
      while (i < text.length && text.charAt(i) !== "'") {
        const next = text.charAt(i + 1);
        if (fish && text.charAt(i) === "\\" && (next === "'" || next === "\\")) {
          out += next;
          i += 2;
        } else {
          out += text.charAt(i);
          i += 1;
        }
      }
      i += 1;
    } else if (c === '"') {
      i += 1;
      while (i < text.length && text.charAt(i) !== '"') {
        const next = text.charAt(i + 1);
        if (text.charAt(i) === "\\" && next !== "" && '$`"\\\n'.includes(next)) {
          out += next;
          i += 2;
        } else {
          out += text.charAt(i);
          i += 1;
        }
      }
      i += 1;
    } else if (c === "$" && text.charAt(i + 1) === "'") {
      i += 2;
      while (i < text.length && text.charAt(i) !== "'") {
        if (text.charAt(i) === "\\" && i + 1 < text.length) {
          const next = text.charAt(i + 1);
          out += ANSI_ESCAPES[next] ?? `\\${next}`;
          i += 2;
        } else {
          out += text.charAt(i);
          i += 1;
        }
      }
      i += 1;
    } else if (c === "\\" && i + 1 < text.length) {
      out += text.charAt(i + 1);
      i += 2;
    } else {
      out += c;
      i += 1;
    }
  }
  return out;
}

/**
 * Replaces the first word with its alias value, repeatedly, the way the shell would. Only done
 * once the user has moved past the first word, and only for values that are one simple command
 * (an alias containing `;`, `|` or `&&` is left alone). The substituted words keep the span of the
 * alias word in the buffer.
 */
export function expandAliases(command: Command, aliases: AliasMap): Command {
  let tokens = command.tokens;
  const used = new Set<string>();
  for (;;) {
    const first = tokens[0];
    if (tokens.length <= 1 || first === undefined || used.has(first.text)) {
      break;
    }
    const value = aliases.get(first.text);
    if (value === undefined) {
      break;
    }
    used.add(first.text);
    const words = wordsOfSimpleCommand(value);
    if (words === null) {
      continue;
    }
    const replaced: Token[] = words.map((word) => ({
      text: word.text,
      start: first.start,
      end: first.end,
      offsets: word.offsets.map(() => first.start),
      complete: true,
    }));
    tokens = [...replaced, ...tokens.slice(1)];
  }
  return tokens === command.tokens ? command : { ...command, tokens };
}
