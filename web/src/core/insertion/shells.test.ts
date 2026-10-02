/**
 * Insertion escaping, checked against the real shells: every hostile file name is inserted outside
 * quotes and inside an open single or double quote, in full and as Tab's shared prefix, and the
 * resulting word is read back by zsh, bash and fish (each where installed) with `printf`. A name
 * that broke out of its quoting would print `INJECTED` or a different word.
 */
import { spawnSync } from "node:child_process";
import { describe, expect, it } from "vitest";
import { getCommand, quoteAt } from "../shell/tokenize";
import type { Item } from "../suggestions/types";
import { type InsertionContext, escapedName, fullInsertionText, insertionBytes } from "./insert";

const NAMES = [
  "a\\'; printf INJECTED; #",
  "a\\'\"; printf INJECTED; #",
  "it's.txt",
  "My File.txt",
  "a$b.txt",
  "a$(printf INJECTED).txt",
  "a`printf INJECTED`.txt",
  "a!b.txt",
  "a\\b.txt",
  'a"b.txt',
  "a(b).txt",
  "a;b",
  "{a,b}",
  "~x",
  "%self",
  "a'b\"c\\d",
];

const SHELLS: Record<string, string[]> = {
  zsh: ["-f", "-c"],
  bash: ["--norc", "--noprofile", "-c"],
  fish: ["--no-config", "-c"],
};

function installed(shell: string): boolean {
  try {
    return spawnSync(shell, [...(SHELLS[shell] ?? []), "exit 0"], { timeout: 5_000 }).status === 0;
  } catch {
    return false;
  }
}

/** Plays `bytes` at the end of `buffer` as a line editor would (backspace deletes, the rest is text). */
function typeInto(buffer: string, bytes: string): string {
  let line = buffer;
  for (const char of bytes) {
    line = char === "\b" ? line.slice(0, -1) : line + char;
  }
  return line;
}

const PATHS: Fig.Generator = { getQueryTerm: (term: string) => term.slice(term.lastIndexOf("/") + 1) };

function context(buffer: string, shell: string): InsertionContext {
  const token = getCommand(buffer, shell)?.tokens.at(-1) ?? null;
  return { searchTerm: token?.text ?? "", buffer, token, fuzzy: false, preferVerbose: false, insertSpace: true, shell };
}

/** The word `cat <prefix>` + completing `name` leaves, closed if a quote is still open. */
function completedWord(prefix: string, name: string, shell: string, complete: boolean): string {
  const buffer = `cat ${prefix}`;
  const ctx = context(buffer, shell);
  const item: Item = { type: "file", names: [name], generator: PATHS };
  const text = complete ? fullInsertionText(item, ctx, false) : escapedName(item, name, ctx, false);
  const bytes = insertionBytes(item, text, ctx, complete);
  expect(bytes).not.toBeNull();
  const line = typeInto(buffer, bytes ?? "");
  const open = quoteAt(line, 4, line.length, shell === "fish");
  return line.slice(4) + (open === null ? "" : open === '"' ? '"' : "'");
}

describe.each(Object.keys(SHELLS))("escaping for %s", (shell) => {
  const cases = ["src/", "'src/", '"src/'].flatMap((prefix) =>
    [true, false].map((complete) => ({ prefix, complete })),
  );

  it.each(cases)("$prefix, complete $complete: every name reads back as itself", ({ prefix, complete }) => {
    const words = NAMES.map((name) => completedWord(prefix, name, shell, complete));
    if (!installed(shell)) {
      return;
    }
    const script = words.map((word) => `printf '<%s>\\n' ${word}`).join("\n");
    const result = spawnSync(shell, [...(SHELLS[shell] ?? []), script], { encoding: "utf8", timeout: 10_000 });
    expect(result.stdout.trimEnd().split("\n")).toEqual(NAMES.map((name) => `<src/${name}>`));
  });
});

describe("fish (review 2, item 2)", () => {
  it("escapes backslashes and quotes inside single quotes", () => {
    expect(completedWord("'src/", "a\\'; printf INJECTED; #", "fish", true)).toBe("'src/a\\\\\\'; printf INJECTED; #'");
    expect(completedWord("src/", "a\\'\"; printf INJECTED; #", "fish", true)).toBe(
      "src/'a\\\\\\'\"; printf INJECTED; #'",
    );
  });

  it("does not put a backslash before a backtick inside double quotes", () => {
    expect(completedWord('"src/', "a`b.txt", "fish", true)).toBe('"src/a`b.txt"');
  });

  it("reads a fish line with escaped quotes inside single quotes as fish does", () => {
    expect(getCommand("cat 'it\\'s ", "fish")?.tokens.map((token) => token.text)).toEqual(["cat", "it's "]);
    expect(getCommand("cat 'it\\'s ", "zsh")?.tokens.map((token) => token.text)).toEqual(["cat", "it\\s", ""]);
  });
});
