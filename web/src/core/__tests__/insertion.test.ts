/**
 * Insertion semantics (UI doc §4), including the worked table of §4.8, through createCore.
 */
import { describe, expect, it } from "vitest";
import { escapeInsertion, fullInsertionText, insertionBytes } from "../insertion/insert";
import { getCommand } from "../shell/tokenize";
import type { Item } from "../suggestions/types";
import { HOME, MONO, harness, monorepoBridge, select, shown, withSpecs } from "./fixtures";

const xSpec: Fig.Spec = {
  name: "x",
  args: { name: "file", isOptional: true, suggestions: [{ name: "lit", insertValue: "a {cursor} b" }, "plain"] },
  options: [
    { name: "--out", requiresEquals: true, args: { name: "path" } },
    { name: ["-m", "--message"], args: { name: "message" } },
    { name: "--sep", requiresSeparator: ":", args: { name: "value" } },
    { name: "--flag" },
  ],
};

describe("UI doc §4.8 table", () => {
  it("cd  → Sites/ types Sites/ and re-shows for the new folder", async () => {
    const h = harness(monorepoBridge(), {}, HOME);
    await h.typeOut("cd ");
    await select(h, "Sites/");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["Sites/"]);
    expect(h.core.getState().visible).toBe(false);
    expect(await h.echo()).toBe("cd Sites/");
    expect(h.core.getState().visible).toBe(true);
    expect(shown(h.core)).toEqual(["↪", "figo/", "mono/", ".something/", "../"]);
  });

  it("cd si → Sites/ deletes what was typed in the wrong case", async () => {
    const h = harness(monorepoBridge(), {}, HOME);
    await h.typeOut("cd si");
    expect(shown(h.core)[0]).toBe("Sites/");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["\b\bSites/"]);
    expect(await h.echo()).toBe("cd Sites/");
    expect(h.core.getState().visible).toBe(true);
  });

  it("cd  → Beta Projects/ escapes the space", async () => {
    const bridge = monorepoBridge().setDirectory(HOME, ["Beta Projects/", "it's/", "a;b"]);
    const h = harness(bridge, {}, HOME);
    await h.typeOut("cd ");
    await h.press("insertSelected");
    expect(bridge.inserts()).toEqual(["Beta\\ Projects/"]);
    expect(h.core.getState().suggestions[0]?.icon).toBe("fig://path/Users/test/Beta%20Projects/");
    bridge.setDirectory(`${HOME}/Beta Projects`, ["src/"]);
    expect(await h.echo()).toBe("cd Beta\\ Projects/");
    expect(h.core.getState().visible).toBe(true);
  });

  it("git  → remote (has subcommands) types remote with a space and re-shows on the new argument", async () => {
    const h = harness();
    await h.typeOut("git ");
    await select(h, "remote");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["remote "]);
    await h.echo();
    expect(h.core.getState().visible).toBe(true);
    expect(shown(h.core)).toContain("add");
  });

  it("git  → checkout gets no space: its argument is optional and it has no subcommands", async () => {
    // The doc's example assumes a space; the shouldAddSpace rule it states gives none for checkout.
    const h = harness();
    await h.typeOut("git ");
    await select(h, "checkout");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["checkout"]);
    await h.echo();
    expect(h.core.getState().visible).toBe(false);
  });

  it("ls  → -l types -l", async () => {
    const h = harness();
    await h.typeOut("ls -");
    await select(h, "-l");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["l"]);
    await h.echo();
    // The doc expects the popup to stay hidden. Upstream's code (and Figo) treat the option
    // chain `-l` as a new argument and show it again, offering `-l` and `-la`, `-lA`, …
    expect(h.core.getState().visible).toBe(true);
    expect(shown(h.core).slice(0, 3)).toEqual(["-l", "-l", "-l,"]);
  });

  it("x  → --out= (requiresEquals) puts the cursor after the =", async () => {
    const h = harness(monorepoBridge(), withSpecs({ x: xSpec }));
    await h.typeOut("x --o");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["ut= \x1b[D"]);
    const { buffer, cursor } = h.bridge.echoLastInsert();
    expect([buffer, cursor]).toEqual(["x --out= ", 8]);
    await h.idle();
    // The cursor sits on the option's value now: nothing to suggest, so the argument hint shows.
    expect(h.core.getState()).toMatchObject({ visible: true, suggestions: [], argument: { name: "path" } });
  });

  it("cd Sites/ → ↪ runs the command", async () => {
    const h = harness(monorepoBridge(), {}, HOME);
    await h.typeOut("cd Sites/");
    expect(shown(h.core)[0]).toBe("↪");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["\n"]);
  });
});

describe("insertion details", () => {
  it("keeps what was typed when the insertion starts with it", async () => {
    const h = harness(monorepoBridge(), {}, HOME);
    await h.typeOut("cd Si");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["tes/"]);
  });

  it("replaces escaped and quoted input exactly", async () => {
    const bridge = monorepoBridge().setDirectory(HOME, ["My Documents/"]);
    const h = harness(bridge, {}, HOME);
    await h.set("cd My\\ Do");
    await h.press("showAutocomplete");
    await h.press("insertSelected");
    expect(bridge.inserts()).toEqual(["cuments/"]);

    await h.set("");
    await h.set('cd "My Do');
    await h.press("showAutocomplete");
    await h.press("insertSelected");
    expect(bridge.inserts().at(-1)).toBe("\b\b\b\b\b\bMy\\ Documents/");
  });

  it("quotes names with shell characters", () => {
    expect(escapeInsertion("it's/", true)).toBe(`'it'"'"'s'/`);
    expect(escapeInsertion("a;b", false)).toBe("'a;b'");
    expect(escapeInsertion("a b", false)).toBe("a\\ b");
    expect(escapeInsertion("$HOME", false)).toBe("'$HOME'");
    expect(escapeInsertion("--out={cursor}", false)).toBe("--out={cursor}");
  });

  it("honours {cursor} in an insert value and does not escape insert values", async () => {
    const h = harness(monorepoBridge(), withSpecs({ x: xSpec }));
    await h.typeOut("x l");
    await select(h, "lit");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["\ba  b\x1b[D\x1b[D"]);
  });

  it("uses the option's own separator", async () => {
    const h = harness(monorepoBridge(), withSpecs({ x: xSpec }));
    await h.typeOut("x --se");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["p: \x1b[D"]);
  });

  it("inserts the longest name with preferVerboseSuggestions", async () => {
    const bridge = monorepoBridge();
    bridge.settings = { "autocomplete.preferVerboseSuggestions": true };
    const h = harness(bridge, withSpecs({ x: xSpec }));
    await h.typeOut("x -");
    await select(h, "-m");
    await h.press("insertSelected");
    // `-` was typed, and `--message ` starts with it.
    expect(bridge.inserts()).toEqual(["-message "]);
  });

  it("omits the trailing space when insertSpaceAutomatically is off", async () => {
    const bridge = monorepoBridge();
    bridge.settings = { "autocomplete.insertSpaceAutomatically": false };
    const h = harness(bridge);
    await h.typeOut("git checko");
    await select(h, "checkout");
    await h.press("insertSelected");
    expect(bridge.inserts()).toEqual(["ut"]);
  });

  it("insertSelectedAndExecute adds one newline; execute sends only a newline", async () => {
    const h = harness(monorepoBridge(), withSpecs({ x: xSpec }));
    await h.typeOut("x pla");
    await h.press("insertSelectedAndExecute");
    expect(h.bridge.inserts()).toEqual(["in\n"]);
    await h.typeOut("x pla", "");
    await h.press("execute");
    expect(h.bridge.inserts().at(-1)).toBe("\n");
    expect(h.bridge.callsTo("shell.insert").at(-1)).toEqual({ sessionId: "session-1", text: "\n" });
  });

  it("sends the buffer the list was computed from as insertionBuffer", async () => {
    const h = harness();
    await h.typeOut("git sta");
    await select(h, "status");
    await h.press("insertSelected");
    expect(h.bridge.callsTo("shell.insert")).toEqual([
      { sessionId: "session-1", text: "tus", insertionBuffer: "git sta" },
    ]);
  });

  it("works out insertion bytes for history entries from inside the quotes", () => {
    const buffer = 'git commit -m "fi';
    const token = getCommand(buffer)?.tokens.at(-1) ?? null;
    const item: Item = { type: "history", names: ['fix bug"'], insertValue: 'fix bug"' };
    const context = { searchTerm: "fi", buffer, token, fuzzy: false, preferVerbose: false, insertSpace: true };
    expect(insertionBytes(item, fullInsertionText(item, context, false), context, true)).toBe('x bug"');
  });
});

describe("common prefix (Tab)", () => {
  it("inserts the shared prefix and keeps the list open", async () => {
    const bridge = monorepoBridge().setDirectory(MONO, ["Projects/", "Programs/", "Prometheus/", "Other/"]);
    const h = harness(bridge);
    await h.typeOut("cd P");
    expect(h.core.getState().commonPrefix).toEqual([1, 3]);
    await h.press("insertCommonPrefix");
    expect(bridge.inserts()).toEqual(["ro"]);
    expect(h.core.getState().visible).toBe(true);
    await h.echo();
    expect(h.core.getState().visible).toBe(true);
    expect(shown(h.core)).toEqual(["Programs/", "Projects/", "Prometheus/"]);
  });

  it("inserts the item when it is the only one", async () => {
    const h = harness(monorepoBridge(), withSpecs({ x: xSpec }));
    await h.typeOut("x pla");
    expect(shown(h.core)).toEqual(["plain"]);
    await h.press("insertCommonPrefix");
    expect(h.bridge.inserts()).toEqual(["in"]);
    expect(h.core.getState().visible).toBe(false);
  });

  it("shakes when there is nothing to add, or navigates / inserts with the other variants", async () => {
    const h = harness(monorepoBridge(), {}, HOME);
    await h.typeOut("cd D");
    expect(shown(h.core)).toEqual(["Desktop/", "Documents/"]);
    expect(h.core.getState().commonPrefix).toBeNull();
    await h.press("insertCommonPrefix");
    expect(h.core.getState().shakeCount).toBe(1);
    expect(h.bridge.inserts()).toEqual([]);
    await h.press("insertCommonPrefixOrNavigateDown");
    expect(h.core.getState().selectedIndex).toBe(1);
    await h.press("insertCommonPrefixOrInsertSelected");
    expect(h.bridge.inserts()).toEqual(["ocuments/"]);
  });
});
