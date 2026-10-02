/**
 * Text that comes from file names and generator output is data: it never reaches the shell as
 * keystrokes, and it cannot give itself the powers of a spec-defined suggestion.
 */
import { describe, expect, it } from "vitest";
import { fullInsertionText, insertionBytes } from "../insertion/insert";
import { getCommand } from "../shell/tokenize";
import type { Item } from "../suggestions/types";
import { HOME, MONO, harness, monorepoBridge, select, shown, withSpecs } from "./fixtures";

/** C0 controls and DEL, which a terminal turns into editing keys (and C1, for good measure). */
const CONTROL = /[\u0000-\u001f\u007f-\u009f]/;

/** Whether an insertion carries anything but backspaces, text, cursor-left and one final newline. */
function hasStrayControls(text: string): boolean {
  const body = text.replace(/^\x08+/, "").replace(/(\x1b\[D)+$/, "").replace(/\n$/, "");
  return CONTROL.test(body);
}

function context(buffer: string) {
  const token = getCommand(buffer)?.tokens.at(-1) ?? null;
  return { searchTerm: token?.text ?? "", buffer, token, fuzzy: false, preferVerbose: false, insertSpace: true };
}

/** A spec whose only argument comes from one generator. */
function generatorSpec(name: string, generator: Fig.Generator, arg: Partial<Fig.Arg> = {}): Fig.Spec {
  return { name, args: { name: "value", generators: generator, ...arg } };
}

describe("control characters (C2)", () => {
  it("never lists a file name with control characters, so Tab on a single match cannot type them", async () => {
    const bridge = monorepoBridge().setDirectory(HOME, ["x\u0015true\r", "notes.txt"]);
    const h = harness(bridge, {}, HOME);
    await h.typeOut("cat x");
    expect(h.core.getState().suggestions).toEqual([]);
    await h.press("insertCommonPrefix");
    await h.press("insertSelected");
    expect(bridge.inserts()).toEqual([]);
  });

  it("does not let a newline in a file name forge directory entries", async () => {
    const bridge = monorepoBridge().setDirectory(HOME, ["first\nforged.txt", "plain.txt"]);
    const h = harness(bridge, {}, HOME);
    await h.typeOut("cat ");
    const files = h.core.getState().suggestions.filter((s) => s.type === "file" || s.type === "folder");
    expect(files.map((s) => s.names[0])).toEqual(["plain.txt", "../"]);
  });

  it("drops generator values with control characters", async () => {
    const spec = generatorSpec("gen", { script: ["list-values"], splitOn: "\n" });
    const bridge = monorepoBridge().onProcess("list-values", { stdout: "good\nbad\u001b[2J\nworse\u007f\nfine\u0085x" });
    const h = harness(bridge, withSpecs({ gen: spec }));
    await h.typeOut("gen ");
    expect(shown(h.core)).toEqual(["good"]);
  });

  it("drops generator objects whose names have control characters, and ignores such insert values", async () => {
    const spec = generatorSpec("gen", {
      script: ["list-values"],
      postProcess: () => [
        { name: "a\u0015b" },
        { name: ["c", "d\rx"] },
        { name: "e", insertValue: "e\u0015touch x" },
      ],
    });
    const bridge = monorepoBridge().onProcess("list-values", { stdout: "x" });
    const h = harness(bridge, withSpecs({ gen: spec }));
    await h.typeOut("gen ");
    expect(shown(h.core)).toEqual(["c", "e"]);
    await select(h, "e");
    await h.press("insertSelected");
    expect(bridge.inserts()).toEqual(["e"]);
  });

  it("refuses to emit control characters as a last line of defence", () => {
    const ctx = context("x a");
    const bad: Item[] = [
      { type: "arg", names: ["a\u0015b"] },
      { type: "file", names: ["a\rb"] },
      { type: "arg", names: ["a"], insertValue: "a\u001b[2J", generator: {} },
      { type: "arg", names: ["a"], insertValue: "a\bb", generator: {} },
      { type: "history", names: ["a\necho two"], insertValue: "a\necho two" },
      // A newline anywhere but at the very end would run part of the line.
      { type: "arg", names: ["a"], insertValue: "a\nb" },
    ];
    for (const item of bad) {
      expect(insertionBytes(item, fullInsertionText(item, ctx, false), ctx, true)).toBeNull();
    }
  });

  it("keeps a spec's own newline, backspace and {cursor}", () => {
    const ctx = context("x a");
    const run: Item = { type: "shortcut", names: ["a"], insertValue: "a\n" };
    expect(insertionBytes(run, fullInsertionText(run, ctx, false), ctx, true)).toBe("\n");
    const erase: Item = { type: "arg", names: ["ab"], insertValue: "\b\bab" };
    expect(insertionBytes(erase, fullInsertionText(erase, ctx, false), ctx, true)).toBe("\b\b\bab");
    const cursor: Item = { type: "arg", names: ["ab"], insertValue: "a{cursor}b" };
    expect(insertionBytes(cursor, fullInsertionText(cursor, ctx, false), ctx, true)).toBe("b\x1b[D");
  });

  it("never sends stray control characters for the worked examples", async () => {
    const h = harness();
    await h.typeOut("git checkout ");
    await h.press("insertSelected");
    await h.typeOut("nr ", "");
    await h.press("insertSelectedAndExecute");
    expect(h.bridge.inserts().length).toBe(2);
    expect(h.bridge.inserts().filter(hasStrayControls)).toEqual([]);
  });
});

/** A project whose package.json `fig` section tries to give its scripts more power. */
const HOSTILE_PACKAGE = JSON.stringify({
  name: "project",
  scripts: { build: "tsc", dev: "vite", lint: "eslint .", test: "vitest" },
  fig: {
    build: { insertValue: "build; printf INJECTED", displayName: "build" },
    dev: { insertValue: "dev --watch" },
    lint: { type: "auto-execute", icon: "https://example.com/icon.png" },
    test: { insertValue: "test; touch marker\n", type: "shortcut", displayName: "test" },
  },
});

function hostileBridge() {
  return monorepoBridge().onProcess(/^bash -c until \[\[ -f package\.json \]\]/, { stdout: HOSTILE_PACKAGE });
}

describe("generator output cannot choose its own power (C3)", () => {
  it("accepts only argument-like types from generators", async () => {
    const h = harness(hostileBridge());
    await h.typeOut("npm run ");
    const types = Object.fromEntries(h.core.getState().suggestions.map((s) => [s.names[0], s.type]));
    expect(types).toMatchObject({ build: "arg", lint: "arg", test: "arg" });
    await select(h, "lint");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["lint"]);
  });

  it("shows the real insert text when a generator's insert value differs from its name", async () => {
    const h = harness(hostileBridge());
    await h.typeOut("npm run ");
    expect(shown(h.core)).toContain("dev --watch");
    expect(shown(h.core)).not.toContain("dev");
    await select(h, "dev");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["dev --watch"]);
  });

  it("ignores insert values that could run, chain or redirect anything (review 2, item 1)", async () => {
    const h = harness(hostileBridge());
    await h.typeOut("npm run ");
    // Typed as its own (escaped) name instead, and shown as such.
    expect(shown(h.core)).toContain("build");
    await select(h, "build");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["build"]);

    const unsafe = [
      "a; printf INJECTED",
      "a && printf INJECTED",
      "a | sh",
      "a `id`",
      "a $(id)",
      "a > out",
      "a < in",
      // fish's command substitution, and zsh's glob qualifier that runs code
      "a (id)",
      "*(e:'id':)",
      // zsh's ${(e)…} evaluates its value; `!` pastes a past command (and its `;`) back in
      "${(e):-\\$\\(id\\)}",
      "a !-1",
    ];
    const spec = generatorSpec("gen", {
      script: ["list-values"],
      postProcess: () => unsafe.map((insertValue, i) => ({ name: `value${i}`, insertValue })),
    });
    const bridge = monorepoBridge().onProcess("list-values", { stdout: "x" });
    const g = harness(bridge, withSpecs({ gen: spec }));
    await g.typeOut("gen ");
    expect(shown(g.core)).toEqual(unsafe.map((_, i) => `value${i}`));
    await g.press("insertSelected");
    expect(bridge.inserts()).toEqual(["value0"]);
  });

  it("never lets a generator's display name hide the name it types (review 2, item 4)", async () => {
    const spec = generatorSpec("gen", {
      script: ["list-values"],
      postProcess: () => [
        { name: "publish-production", displayName: "test" },
        { name: "repo", displayName: "repo - 1a2b3c" },
        { name: "web", displayName: "Spring Web" },
        { name: ["safe", "other"], displayName: "safe" },
        { name: "rm", displayName: "harmless form" },
        { name: "plain", insertValue: "plain; id", displayName: "plain" },
      ],
    });
    const bridge = monorepoBridge().onProcess("list-values", { stdout: "x" });
    const h = harness(bridge, withSpecs({ gen: spec }));
    await h.typeOut("gen ");
    expect(shown(h.core)).toEqual([
      "publish-production (test)",
      // A label that starts with the name already shows it.
      "repo - 1a2b3c",
      "web (Spring Web)",
      "safe, other (safe)",
      "rm (harmless form)",
      "plain",
    ]);
  });

  it("ignores insert values with newlines or control characters", async () => {
    const h = harness(hostileBridge());
    await h.typeOut("npm run ");
    await select(h, "test");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["test"]);
  });

  it("accepts only fig: icons from generators", async () => {
    const h = harness(hostileBridge());
    await h.typeOut("npm run ");
    const lint = h.core.getState().suggestions.find((s) => s.names[0] === "lint");
    expect(lint?.icon).toBeUndefined();
    // The spec's own fig: icon still shows for scripts the section does not touch.
    const fresh = harness();
    await fresh.typeOut("npm run ");
    expect(fresh.core.getState().suggestions[0]?.icon).toBe("fig://icon?type=npm");
  });

  it("escapes plain-string results like any other value", async () => {
    const spec = generatorSpec("gen", { script: ["list-values"], splitOn: "\n" });
    const bridge = monorepoBridge().onProcess("list-values", { stdout: "two words\n$(echo hi)\nplain" });
    const h = harness(bridge, withSpecs({ gen: spec }));
    await h.typeOut("gen t");
    await h.press("insertSelected");
    await h.typeOut("gen $", "");
    await h.press("insertSelected");
    expect(bridge.inserts()).toEqual(["wo\\ words", "\b'$(echo hi)'"]);
  });

  it("honours {cursor} only for spec-defined items", async () => {
    const spec = generatorSpec("gen", {
      script: ["list-values"],
      postProcess: () => [{ name: "pick", insertValue: "a{cursor}b" }],
    });
    const bridge = monorepoBridge()
      .onProcess("list-values", { stdout: "x" })
      .setDirectory(MONO, ["c{cursor}d.txt"]);
    const h = harness(bridge, withSpecs({ gen: spec }));
    await h.typeOut("gen ");
    expect(shown(h.core)).toEqual(["a{cursor}b"]);
    // A generator's insert value that cannot run anything is typed as written, marker included,
    // and no cursor movement follows it.
    await h.press("insertSelected");
    await h.typeOut("cat c", "");
    await h.press("insertSelected");
    expect(bridge.inserts()).toEqual(["a{cursor}b", "\b'c{cursor}d.txt'"]);
  });

  it("keeps an argument's danger even when a generator says otherwise", async () => {
    const spec = generatorSpec(
      "gen",
      { script: ["list-values"], postProcess: () => [{ name: "target", isDangerous: false }] },
      { isDangerous: true },
    );
    const bridge = monorepoBridge().onProcess("list-values", { stdout: "x" });
    const h = harness(bridge, withSpecs({ gen: spec }));
    await h.typeOut("gen target");
    // No run-it twin on top: accepting must not run a dangerous command straight away.
    expect(h.core.getState().suggestions.map((s) => s.type)).toEqual(["arg"]);
    expect(h.core.getState().suggestions[0]?.isDangerous).toBe(true);
  });
});
