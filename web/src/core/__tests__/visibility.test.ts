/**
 * The visibility state machine (UI doc §5, engine doc §8) and key actions that move it.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { HOME, harness, monorepoBridge, select, shown } from "./fixtures";

afterEach(() => {
  vi.useRealTimers();
});

describe("visibility", () => {
  it("shows on the first keystroke and hides when nothing matches", async () => {
    const h = harness();
    await h.typeOut("git chec");
    expect(h.core.getState().visible).toBe(true);
    await h.typeOut("git checkzz", "git chec");
    // git's root argument is named, so its hint shows instead of a list (UI doc §1.10).
    expect(h.core.getState()).toMatchObject({ visible: true, suggestions: [], argument: { name: "alias" } });
    await h.typeOut("cd zzz", "");
    expect(h.core.getState()).toMatchObject({ visible: false, suggestions: [], argument: null });
  });

  it("Esc keeps the popup hidden for the rest of the line", async () => {
    const h = harness();
    await h.typeOut("git ch");
    await h.press("hideAutocomplete");
    expect(h.core.getState().visible).toBe(false);
    await h.typeOut("git checkout ma", "git ch");
    expect(h.core.getState().visible).toBe(false);
    // Suggestions are still known, so a global show key would work.
    expect(h.core.getState().suggestions.length).toBeGreaterThan(0);
    // A new line (the buffer emptied after running the command) starts afresh.
    h.bridge.type("");
    await h.idle();
    await h.typeOut("git ch");
    expect(h.core.getState().visible).toBe(true);
  });

  it("showAutocomplete and toggleAutocomplete bring it back after Esc", async () => {
    const h = harness();
    await h.typeOut("git ch");
    await h.press("hideAutocomplete");
    await h.press("showAutocomplete");
    expect(h.core.getState().visible).toBe(true);
    await h.press("toggleAutocomplete");
    expect(h.core.getState().visible).toBe(false);
    await h.press("toggleAutocomplete");
    expect(h.core.getState().visible).toBe(true);
  });

  it("is hidden after an insertion that does not lead to a new argument", async () => {
    const h = harness();
    await h.typeOut("git sta");
    await select(h, "status");
    await h.press("insertSelected");
    expect(h.core.getState().visible).toBe(false);
    expect(await h.echo()).toBe("git status");
    expect(h.core.getState().visible).toBe(false);
    // The next keystroke shows it again.
    await h.typeOut("git status ", "git status");
    expect(h.core.getState().visible).toBe(true);
  });

  it("shows again after inserting a folder, for that folder's contents", async () => {
    const h = harness(monorepoBridge(), {}, HOME);
    await h.typeOut("ls Si");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["tes/"]);
    expect(h.core.getState().visible).toBe(false);
    await h.echo();
    expect(h.core.getState().visible).toBe(true);
    expect(shown(h.core)).toEqual(["↪", "figo/", "mono/", ".something/", "../"]);
  });

  it("Up on the first row hides until the next keystroke", async () => {
    const h = harness();
    await h.typeOut("git ch");
    await h.press("navigateDown");
    await h.press("navigateUp");
    expect(h.core.getState()).toMatchObject({ visible: true, selectedIndex: 0 });
    await h.press("navigateUp");
    expect(h.core.getState().visible).toBe(false);
    await h.typeOut("git che", "git ch");
    expect(h.core.getState().visible).toBe(true);
  });

  it("Up on the first row switches to history with navigateToHistory", async () => {
    const bridge = monorepoBridge().onProcess("/bin/zsh -lic fc -R; fc -ln 1", { stdout: "git checkout main\n" });
    bridge.settings = { "autocomplete.navigateToHistory": true };
    const h = harness(bridge);
    await h.typeOut("git ch");
    await h.press("navigateUp");
    expect(h.core.getState()).toMatchObject({ visible: true, historyMode: true });
  });

  it("wraps around with scrollWrapAround", async () => {
    const bridge = monorepoBridge();
    bridge.settings = { "autocomplete.scrollWrapAround": true };
    const h = harness(bridge);
    await h.typeOut("git ch");
    const count = h.core.getState().suggestions.length;
    await h.press("navigateUp");
    expect(h.core.getState()).toMatchObject({ visible: true, selectedIndex: count - 1 });
    await h.press("navigateDown");
    expect(h.core.getState().selectedIndex).toBe(0);
  });

  it("backspacing into the previous token hides", async () => {
    const h = harness();
    await h.typeOut("git checkout ");
    expect(h.core.getState().visible).toBe(true);
    await h.set("git checkout");
    expect(h.core.getState().visible).toBe(false);
  });

  it("a paste or history recall hides until the next keystroke", async () => {
    const h = harness();
    await h.set("git checkout ");
    expect(h.core.getState().visible).toBe(false);
    await h.set("git checkout m");
    expect(h.core.getState().visible).toBe(true);
  });

  it("a cursor inside a word hides, and resets Esc", async () => {
    const h = harness();
    await h.typeOut("git ch");
    await h.press("hideAutocomplete");
    h.bridge.type("git ch", 5);
    await h.idle();
    expect(h.core.getState()).toMatchObject({ visible: false, suggestions: [] });
    await h.set("git che");
    await h.set("git chec");
    expect(h.core.getState().visible).toBe(true);
  });

  it("ignores text after the cursor", async () => {
    const h = harness();
    await h.typeOut("git ");
    h.bridge.type("git  | less", 4);
    await h.idle();
    expect(h.core.getState().visible).toBe(true);
    expect(shown(h.core)).toContain("checkout");
  });

  it.each([
    ["buffer: null", (h: ReturnType<typeof harness>) => h.bridge.type(null)],
    ["preExec", (h: ReturnType<typeof harness>) => h.bridge.emit("preExec", { sessionId: "session-1" })],
    ["windowHidden", (h: ReturnType<typeof harness>) => h.bridge.emit("windowHidden", {})],
  ])("%s resets to hidden", async (_, act) => {
    const h = harness();
    await h.typeOut("git ch");
    act(h);
    await h.idle();
    expect(h.core.getState()).toMatchObject({ visible: false, suggestions: [] });
  });

  it("with onlyShowOnTab stays hidden on a new token until Tab, which completes a single match", async () => {
    const bridge = monorepoBridge();
    bridge.settings = { "autocomplete.onlyShowOnTab": true };
    const h = harness(bridge);
    await h.typeOut("git ch");
    expect(h.core.getState().visible).toBe(false);
    expect(bridge.lastIntercept()?.bindings.tab).toBe("showAutocomplete");
    await h.press("showAutocomplete");
    expect(h.core.getState().visible).toBe(true);
    expect(bridge.lastIntercept()?.bindings.tab).toBe("insertCommonPrefix");
    // No auto-execute entries in this mode.
    expect(h.core.getState().suggestions.every((s) => s.type !== "auto-execute")).toBe(true);

    await h.typeOut("ls -la && git chec", "");
    expect(h.core.getState().visible).toBe(false);
    await h.press("showAutocomplete");
    expect(bridge.inserts()).toEqual(["kout"]);
  });

  it("does nothing on key actions when there are no suggestions", async () => {
    const h = harness();
    await h.typeOut("git checkzz");
    await h.press("insertSelected");
    await h.press("toggleDescription");
    expect(h.bridge.inserts()).toEqual([]);
    expect(h.core.getState().descriptionPopout).toBe(false);
  });
});

describe("loading", () => {
  it("keeps the previous list for 200 ms, then shows the loading state", async () => {
    vi.useFakeTimers();
    const bridge = monorepoBridge();
    let release: (() => void) | null = null;
    const h = harness(bridge, {}, HOME);
    await vi.runAllTimersAsync();
    for (const line of ["c", "cd", "cd ", "cd S", "cd Si", "cd Sit", "cd Site", "cd Sites"]) {
      bridge.type(line);
      await vi.runAllTimersAsync();
    }
    expect(shown(h.core)).toEqual(["Sites", "Sites/"]);
    // Make the next listing slow.
    const original = bridge.call.bind(bridge);
    vi.spyOn(bridge, "call").mockImplementation(((method: string, params: never) => {
      if (method === "fs.list") {
        return new Promise((resolve) => {
          release = () => resolve(original(method as "fs.list", params));
        });
      }
      return original(method as never, params);
    }) as typeof bridge.call);
    bridge.type("cd Sites/");
    await vi.advanceTimersByTimeAsync(150);
    expect(h.core.getState()).toMatchObject({ loading: false, visible: true });
    expect(shown(h.core)).toEqual(["Sites", "Sites/"]);
    await vi.advanceTimersByTimeAsync(100);
    expect(h.core.getState()).toMatchObject({ loading: true, visible: true });
    (release as (() => void) | null)?.();
    await vi.runAllTimersAsync();
    expect(h.core.getState().loading).toBe(false);
    expect(shown(h.core)).toEqual(["↪", "figo/", "mono/", ".something/", "../"]);
  });
});

describe("display actions", () => {
  it("toggleDescription, sizes, and alwaysShowDescription", async () => {
    const h = harness();
    await h.typeOut("git ch");
    await h.press("toggleDescription");
    expect(h.core.getState().descriptionPopout).toBe(true);
    await h.press("increaseSize");
    await h.press("increaseSize");
    expect(h.core.getState().scale).toBeCloseTo(1.21);
    await h.press("decreaseSize");
    expect(h.core.getState().scale).toBeCloseTo(1.1);
    h.bridge.emitSettings({ "autocomplete.alwaysShowDescription": true });
    await h.idle();
    await h.press("toggleDescription");
    expect(h.core.getState().descriptionPopout).toBe(true);
    expect(h.core.getState().settings).toEqual({ "autocomplete.alwaysShowDescription": true });
  });

  it("toggleFuzzySearch switches matching until the argument changes", async () => {
    const h = harness();
    await h.typeOut("git ch");
    // git's subcommand argument has no filter strategy, so the user's preference applies.
    await h.press("toggleFuzzySearch");
    await h.typeOut("git cho", "git ch");
    expect(h.core.getState().suggestions.map((s) => s.names[0])).toContain("checkout");
    expect(h.core.getState().suggestions[0]?.match.ranges.length).toBeGreaterThan(0);
    // A new argument goes back to the setting (prefix matching).
    await h.typeOut("git checkout -- cho", "git cho");
    expect(h.core.getState().suggestions).toEqual([]);
  });
});
