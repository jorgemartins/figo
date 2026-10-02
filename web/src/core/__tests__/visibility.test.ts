/**
 * The visibility state machine (UI doc §5, engine doc §8) and key actions that move it.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { HOME, MONO, harness, monorepoBridge, select, shown } from "./fixtures";

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
    // The branch generators wait for the popup (review H9), but a global show key still works.
    expect(h.bridge.lastIntercept()).toMatchObject({ interceptGlobal: true });
    await h.press("showAutocomplete");
    expect(h.core.getState().visible).toBe(true);
    expect(shown(h.core)[0]).toBe("main");
    await h.press("hideAutocomplete");
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

describe("after a command runs (review M12)", () => {
  it("does not parse or offer the old command line again", async () => {
    const bridge = monorepoBridge();
    bridge.settings = { "autocomplete.onlyShowOnTab": true };
    const h = harness(bridge);
    await h.typeOut("cd ap");
    await h.press("showAutocomplete");
    expect(bridge.inserts()).toEqual(["ps/"]);
    await h.echo();
    // Enter runs `cd apps/`; the shell then reports its new directory.
    bridge.emit("preExec", { sessionId: "session-1" });
    bridge.emit("postExec", { sessionId: "session-1", command: "cd apps/", exitCode: 0 });
    const listings = bridge.callsTo("fs.list").length;
    const runs = bridge.processRuns().length;
    bridge.updateSession({ cwd: `${MONO}/apps` });
    await h.idle();
    expect(bridge.callsTo("fs.list")).toHaveLength(listings);
    expect(bridge.processRuns()).toHaveLength(runs);
    expect(h.core.getState().suggestions).toEqual([]);
    // Tab at the fresh prompt belongs to the shell.
    expect(bridge.lastIntercept()).toMatchObject({ interceptBound: false, interceptGlobal: false });
    await h.press("showAutocomplete");
    expect(bridge.inserts()).toEqual(["ps/"]);
  });
});

describe("generators wait for the popup (review H9)", () => {
  const branchRuns = (h: ReturnType<typeof harness>) =>
    h.bridge.processRuns().filter((run) => run.includes(" branch "));

  it("do not run after Esc until the popup is shown again", async () => {
    const h = harness();
    await h.typeOut("git ch");
    await h.press("hideAutocomplete");
    await h.typeOut("git checkout ", "git ch");
    expect(branchRuns(h)).toEqual([]);
    expect(h.core.getState().visible).toBe(false);
    // A global show key still reaches the core while generators are waiting.
    expect(h.bridge.lastIntercept()).toMatchObject({ interceptBound: false, interceptGlobal: true });
    await h.press("showAutocomplete");
    expect(branchRuns(h)).toHaveLength(1);
    expect(shown(h.core)[0]).toBe("main");
  });

  it("do not run after a paste until the next keystroke shows the popup", async () => {
    const h = harness();
    await h.set("git checkout ");
    expect(h.core.getState().visible).toBe(false);
    expect(branchRuns(h)).toEqual([]);
    await h.typeOut("git checkout m", "git checkout ");
    expect(branchRuns(h)).toHaveLength(1);
    expect(shown(h.core)[0]).toBe("main");
  });

  it("do not run in onlyShowOnTab mode until Tab, which then completes a single match", async () => {
    const bridge = monorepoBridge();
    bridge.settings = { "autocomplete.onlyShowOnTab": true };
    const h = harness(bridge);
    await h.typeOut("git checkout ");
    expect(branchRuns(h)).toEqual([]);
    expect(bridge.lastIntercept()).toMatchObject({ interceptGlobal: true, bindings: { tab: "showAutocomplete" } });
    await h.press("showAutocomplete");
    expect(branchRuns(h)).toHaveLength(1);
    expect(h.core.getState().visible).toBe(true);
    expect(shown(h.core)[0]).toBe("main");

    await h.typeOut("git checkout feat", "");
    expect(h.core.getState().visible).toBe(false);
    await h.press("showAutocomplete");
    expect(bridge.inserts()).toEqual(["ure/login"]);
  });

  it("do not start a debounced run once the popup is dismissed (review 2, item 3)", async () => {
    vi.useFakeTimers();
    const spec: Fig.Spec = {
      name: "deb",
      options: [{ name: "--alpha" }],
      // Fig's types say boolean; a number of milliseconds is honoured too.
      args: { name: "target", debounce: 300, generators: { script: ["list-targets"], splitOn: "\n" } },
    } as unknown as Fig.Spec;
    const bridge = monorepoBridge().onProcess("list-targets", { stdout: "main\nother" });
    const h = harness(bridge, {
      importSpec: async () => ({ default: spec }),
      loadIndex: async () => ({ completions: ["deb"], diffVersionedCompletions: [] }),
    });
    await vi.runAllTimersAsync();
    for (const line of ["d", "de", "deb", "deb "]) {
      bridge.type(line);
      await vi.advanceTimersByTimeAsync(10);
    }
    expect(h.core.getState().visible).toBe(true);
    bridge.press("hideAutocomplete");
    await vi.advanceTimersByTimeAsync(1_000);
    expect(bridge.processRuns()).toEqual([]);
    bridge.press("showAutocomplete");
    await vi.advanceTimersByTimeAsync(1_000);
    expect(bridge.processRuns()).toEqual(["list-targets"]);
    expect(shown(h.core)).toEqual(["main", "other", "--alpha"]);
  });

  it("stop issuing commands for a generator once the popup is dismissed", async () => {
    vi.useFakeTimers();
    const spec: Fig.Spec = {
      name: "steps",
      options: [{ name: "--alpha" }],
      args: {
        name: "target",
        generators: {
          custom: async (_tokens, executeCommand) => {
            const first = await executeCommand({ command: "first-step", args: [] });
            const second = await executeCommand({ command: "second-step", args: [] });
            return [first.stdout, second.stdout].map((name) => ({ name }));
          },
        },
      },
    };
    let releaseFirst: () => void = () => undefined;
    const bridge = monorepoBridge()
      .onProcess(
        "first-step",
        () =>
          new Promise((resolve) => {
            releaseFirst = () => resolve({ stdout: "one" });
          }),
      )
      .onProcess("second-step", { stdout: "two" });
    const h = harness(bridge, {
      importSpec: async () => ({ default: spec }),
      loadIndex: async () => ({ completions: ["steps"], diffVersionedCompletions: [] }),
    });
    await vi.runAllTimersAsync();
    for (const line of ["s", "st", "ste", "step", "steps", "steps "]) {
      bridge.type(line);
      await vi.advanceTimersByTimeAsync(10);
    }
    expect(bridge.processRuns()).toEqual(["first-step"]);
    bridge.press("hideAutocomplete");
    releaseFirst();
    await vi.advanceTimersByTimeAsync(100);
    expect(bridge.processRuns()).toEqual(["first-step"]);
    // Shown again, the generator runs again from the start.
    bridge.press("showAutocomplete");
    await vi.advanceTimersByTimeAsync(10);
    releaseFirst();
    await vi.runAllTimersAsync();
    expect(bridge.processRuns()).toEqual(["first-step", "first-step", "second-step"]);
    expect(shown(h.core)).toEqual(["one", "two", "--alpha"]);
  });

  function memorySpecs(spec: Fig.Spec) {
    return {
      importSpec: async () => ({ default: spec }),
      loadIndex: async () => ({ completions: [spec.name as string], diffVersionedCompletions: [] }),
    };
  }

  it("run with the line as it is when Tab starts them, not as it was planned (review 2, item 6)", async () => {
    vi.useFakeTimers();
    const spec: Fig.Spec = {
      name: "lookup",
      args: { name: "term", generators: { script: (tokens) => ["lookup", tokens.at(-1) ?? ""], splitOn: "\n" } },
    };
    const bridge = monorepoBridge().onProcess(
      (params) => params.executable === "lookup",
      (params) => ({ stdout: `${params.args[0]}-result` }),
    );
    bridge.settings = { "autocomplete.onlyShowOnTab": true };
    harness(bridge, memorySpecs(spec));
    await vi.runAllTimersAsync();
    for (const line of ["l", "lo", "loo", "look", "looku", "lookup", "lookup ", "lookup a", "lookup ab", "lookup abc"]) {
      bridge.type(line);
      await vi.advanceTimersByTimeAsync(10);
    }
    expect(bridge.processRuns()).toEqual([]);
    bridge.press("showAutocomplete");
    await vi.runAllTimersAsync();
    expect(bridge.processRuns()).toEqual(["lookup abc"]);
    // The single match completes, as Tab does in this mode.
    expect(bridge.inserts()).toEqual(["-result"]);
  });

  it("still complete a single match when Tab waits long enough to show the indicator (review 2, item 7)", async () => {
    vi.useFakeTimers();
    const spec: Fig.Spec = {
      name: "slow",
      args: { name: "target", generators: { script: ["list-targets"], splitOn: "\n" } },
    };
    const bridge = monorepoBridge().onProcess(
      "list-targets",
      () => new Promise((resolve) => setTimeout(() => resolve({ stdout: "unique" }), 250)),
    );
    bridge.settings = { "autocomplete.onlyShowOnTab": true };
    const h = harness(bridge, memorySpecs(spec));
    await vi.runAllTimersAsync();
    for (const line of ["s", "sl", "slo", "slow", "slow ", "slow u"]) {
      bridge.type(line);
      await vi.advanceTimersByTimeAsync(10);
    }
    bridge.press("showAutocomplete");
    await vi.advanceTimersByTimeAsync(220);
    expect(h.core.getState()).toMatchObject({ visible: true, loading: true });
    // A second Tab while it waits does nothing (it does not reach the shell's own completion).
    expect(bridge.lastIntercept()).toMatchObject({ interceptGlobal: true, bindings: { tab: "showAutocomplete" } });
    await vi.runAllTimersAsync();
    expect(bridge.inserts()).toEqual(["nique"]);
  });

  it("show the loading indicator when a show key waits on slow generators", async () => {
    vi.useFakeTimers();
    let release: () => void = () => undefined;
    const spec: Fig.Spec = {
      name: "tool",
      options: [{ name: "--alpha" }],
      args: { name: "target", generators: { script: ["list-targets"], splitOn: "\n" } },
    };
    const bridge = monorepoBridge().onProcess(
      "list-targets",
      () =>
        new Promise((resolve) => {
          release = () => resolve({ stdout: "main\nother" });
        }),
    );
    const h = harness(bridge, {
      importSpec: async () => ({ default: spec }),
      loadIndex: async () => ({ completions: ["tool"], diffVersionedCompletions: [] }),
    });
    await vi.runAllTimersAsync();
    bridge.type("tool ");
    await vi.advanceTimersByTimeAsync(10);
    expect(bridge.processRuns()).toEqual([]);
    bridge.press("showAutocomplete");
    await vi.advanceTimersByTimeAsync(50);
    expect(bridge.processRuns()).toEqual(["list-targets"]);
    // Not a partial list (just the option) while the targets load...
    expect(h.core.getState().visible).toBe(false);
    await vi.advanceTimersByTimeAsync(200);
    // ...but the indicator once they take a while.
    expect(h.core.getState()).toMatchObject({ visible: true, loading: true });
    release();
    await vi.runAllTimersAsync();
    expect(shown(h.core)).toEqual(["main", "other", "--alpha"]);
  });

  it("do not run for a new directory when the shell reports one while the popup is hidden", async () => {
    const h = harness();
    await h.typeOut("cd ");
    await h.press("hideAutocomplete");
    h.bridge.clearCalls();
    h.bridge.updateSession({ cwd: `${MONO}/apps` });
    await h.idle();
    expect(h.bridge.callsTo("fs.list")).toEqual([]);
    await h.press("showAutocomplete");
    expect(h.bridge.callsTo("fs.list").map((call) => call.path)).toEqual([`${MONO}/apps/`]);
    expect(shown(h.core)).toEqual(["api/", "web/", "../"]);
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

  it("does not take Enter or Tab while the list is hidden behind the indicator (review M3)", async () => {
    vi.useFakeTimers();
    let release: () => void = () => undefined;
    const spec: Fig.Spec = {
      name: "tool",
      options: [{ name: "--alpha" }, { name: "--beta" }],
      args: { name: "target", generators: { script: ["list-targets"], splitOn: "\n" } },
    };
    const bridge = monorepoBridge().onProcess(
      "list-targets",
      () =>
        new Promise((resolve) => {
          release = () => resolve({ stdout: "main\nother" });
        }),
    );
    const h = harness(bridge, {
      importSpec: async () => ({ default: spec }),
      loadIndex: async () => ({ completions: ["tool"], diffVersionedCompletions: [] }),
    });
    await vi.runAllTimersAsync();
    for (const line of ["t", "to", "too", "tool", "tool "]) {
      bridge.type(line);
      await vi.advanceTimersByTimeAsync(10);
    }
    await vi.advanceTimersByTimeAsync(300);
    const state = h.core.getState();
    // Options are known, but the indicator is what is on screen.
    expect(state).toMatchObject({ loading: true, visible: true });
    expect(state.suggestions.length).toBeGreaterThan(0);
    expect(bridge.lastIntercept()).toMatchObject({ interceptBound: false });
    // A key that was already on its way when the indicator appeared does nothing either.
    bridge.press("insertSelected");
    bridge.press("insertCommonPrefix");
    expect(bridge.inserts()).toEqual([]);
    release();
    await vi.runAllTimersAsync();
    expect(h.core.getState().loading).toBe(false);
    expect(bridge.lastIntercept()).toMatchObject({ interceptBound: true });
    expect(shown(h.core)[0]).toBe("main");
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
