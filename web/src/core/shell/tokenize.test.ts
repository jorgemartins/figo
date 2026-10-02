import { describe, expect, it } from "vitest";
import { expandAliases, parseAliases, unquote } from "./aliases";
import { getCommand, quoteAt, sourceStartOf, splitCommands, wordsOfSimpleCommand } from "./tokenize";

function words(buffer: string): string[] | null {
  return getCommand(buffer)?.tokens.map((token) => token.text) ?? null;
}

describe("getCommand", () => {
  it.each([
    // Engine doc §2.4
    ["git checkout ", ["git", "checkout", ""]],
    ["echo hi | grep -i ", ["grep", "-i", ""]],
    ["make && npm r", ["npm", "r"]],
    ["(cd app; ls ", ["ls", ""]],
    ["FOO=1 BAR=2 node ", ["node", ""]],
    ["FOO=1 ", [""]],
    ['git commit -m "fix ', ["git", "commit", "-m", "fix "]],
    // More of §2.2 and §2.3
    ["ls My\\ Dir", ["ls", "My Dir"]],
    ["ls My\\ ", ["ls", "My "]],
    ["echo 'a b' \"c d\" e", ["echo", "a b", "c d", "e"]],
    ['echo "a\\"b" \'c\\d\'', ["echo", 'a"b', "c\\d"]],
    ['echo "foo"bar$X', ["echo", "foobar$X"]],
    ["ls $HOME/x", ["ls", "$HOME/x"]],
    ["echo $(git ch", ["git", "ch"]],
    ["echo `git ch", ["git", "ch"]],
    ['echo "$(git ch', ["git", "ch"]],
    ["echo $(ls) ", ["echo", "$(ls)", ""]],
    ["a && ", [""]],
    ["{ ls; git st", ["git", "st"]],
    ["diff <(git sh", ["git", "sh"]],
    ["sudo git checkout ma", ["sudo", "git", "checkout", "ma"]],
    ["ls\t", ["ls"]],
    ["git a\\\nb", ["git", "ab"]],
    ["echo one\ngit ", ["git", ""]],
    ["! git st", ["git", "st"]],
    ["echo ${HOME} ", ["echo", "${HOME}", ""]],
    // Reserved words before a command are not the command (review L19).
    ["if true; then git ch", ["git", "ch"]],
    ["while true; do ls ", ["ls", ""]],
    ["if git st", ["git", "st"]],
    ["time FOO=1 git st", ["git", "st"]],
    // bash's `time -p` (review 2, item 8); a dash anywhere else is still an argument.
    ["time -p git st", ["git", "st"]],
    ["time -p", ["-p"]],
    ["if -p x", ["-p", "x"]],
    ["if true; then", ["then"]],
    ["echo then ", ["echo", "then", ""]],
    ["'then' x", ["then", "x"]],
  ])("%j → %j", (buffer, expected) => {
    expect(words(buffer)).toEqual(expected);
  });

  it.each([[""], ["a &&"], ["a;"], ["FOO=1"], ["ls # a comment"], ["(cd app)"], ["ls 2>&1"]])(
    "%j has nothing to complete",
    (buffer) => {
      expect(getCommand(buffer)).toBeNull();
    },
  );

  it("records where each word is in the buffer", () => {
    const command = getCommand('cd "My Do');
    const token = command?.tokens[1];
    expect(token).toMatchObject({ text: "My Do", start: 3, end: 9, complete: false });
    expect(token?.offsets).toEqual([4, 5, 6, 7, 8, 9]);
  });

  it("treats redirection targets as file names, not arguments", () => {
    expect(getCommand("cat x > ")).toMatchObject({ redirectTarget: true });
    expect(words("cat x > ")).toEqual(["cat", "x", ""]);
    expect(words("cat x >ou")).toEqual(["cat", "x", "ou"]);
    expect(getCommand("cat x >ou")?.redirectTarget).toBe(true);
    expect(words("cat x > out ")).toEqual(["cat", "x", ""]);
    expect(getCommand("cat x > out ")?.redirectTarget).toBe(false);
    expect(words("make 2>&1 | grep e")).toEqual(["grep", "e"]);
    expect(words("cmd 2>/dev/null ")).toEqual(["cmd", ""]);
  });
});

describe("sourceStartOf", () => {
  it("includes opening quotes right before the replaced part", () => {
    const buffer = 'cd ~/"My Do';
    const token = getCommand(buffer)?.tokens[1];
    expect(token?.text).toBe("~/My Do");
    expect(token && buffer.slice(sourceStartOf(token, 2, buffer))).toBe('"My Do');
    expect(token && buffer.slice(sourceStartOf(token, 0, buffer))).toBe('~/"My Do');
  });

  it("counts escapes as typed", () => {
    const buffer = "cd My\\ Do";
    const token = getCommand(buffer)?.tokens[1];
    expect(token && buffer.slice(sourceStartOf(token, 0, buffer))).toBe("My\\ Do");
  });
});

describe("quoteAt", () => {
  it.each<[string, number, string | null]>([
    ['"src/My F', 5, '"'],
    ['"src/My F', 0, null],
    ["'src/it'\\''s ", 5, "'"],
    ["'src/it'\\''s ", 13, "'"],
    ["'src/it'\\''s ", 9, null],
    ['"a\\"b', 5, '"'],
    ['"a"b', 4, null],
    ["a\\'b", 4, null],
    ["$'a\\'b", 6, "$'"],
    ["\"it's", 5, '"'],
  ])("%j at %i → %j", (buffer, to, expected) => {
    expect(quoteAt(buffer, 0, to)).toBe(expected);
  });
});

describe("splitCommands", () => {
  it("returns every simple command of a line", () => {
    expect(splitCommands("cd app && git status | less; ls -la ").map((c) => c.tokens.map((t) => t.text))).toEqual([
      ["cd", "app"],
      ["git", "status"],
      ["less"],
      ["ls", "-la"],
    ]);
  });
});

describe("aliases", () => {
  it("parses zsh output", () => {
    const aliases = parseAliases("g=git\nll='ls -l'\nquote='echo '\\''hi'\\'''\nmulti='echo one\necho two'", "zsh");
    expect(Object.fromEntries(aliases)).toEqual({
      g: "git",
      ll: "ls -l",
      quote: "echo 'hi'",
      multi: "echo one\necho two",
    });
  });

  it("parses bash output", () => {
    const aliases = parseAliases("alias g='git'\nalias ll='ls -la'\n", "bash");
    expect(Object.fromEntries(aliases)).toEqual({ g: "git", ll: "ls -la" });
  });

  it("parses fish output", () => {
    const aliases = parseAliases("alias g git\nalias ll 'ls -l'\nalias it 'echo it\\'s'", "fish");
    expect(Object.fromEntries(aliases)).toEqual({ g: "git", ll: "ls -l", it: "echo it's" });
  });

  it("unquotes like the shell", () => {
    expect(unquote(`'a b'"c"\\ d$'\\n'`)).toBe("a bc d\n");
  });

  it("expands the first word once the user has moved past it", () => {
    const aliases = new Map([
      ["g", "git"],
      ["gco", "g checkout"],
      ["bad", "echo a | grep b"],
    ]);
    const expand = (buffer: string) => {
      const command = getCommand(buffer);
      return command ? expandAliases(command, aliases).tokens.map((token) => token.text) : null;
    };
    expect(expand("g")).toEqual(["g"]);
    expect(expand("g ")).toEqual(["git", ""]);
    expect(expand("gco ma")).toEqual(["git", "checkout", "ma"]);
    expect(expand("bad x")).toEqual(["bad", "x"]);
    expect(expand("if true; then g ch")).toEqual(["git", "ch"]);
  });

  it("only substitutes single simple commands", () => {
    expect(wordsOfSimpleCommand("ls -l ")?.map((token) => token.text)).toEqual(["ls", "-l"]);
    expect(wordsOfSimpleCommand("a; b")).toBeNull();
    expect(wordsOfSimpleCommand("a && b")).toBeNull();
    expect(wordsOfSimpleCommand("echo 'open")).toBeNull();
    expect(wordsOfSimpleCommand("echo $(date)")?.map((token) => token.text)).toEqual(["echo", "$(date)"]);
  });
});
