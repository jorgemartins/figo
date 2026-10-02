/**
 * Generators (engine doc §5): triggers, caching, templates, and how they reach the bridge.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_MAX_AGE_MS, GeneratorCache } from "../generators/cache";
import { shouldRetrigger } from "../generators/trigger";
import { fuzzyMatch } from "../suggestions/fuzzy";
import { HOME, MONO, PACKAGE_JSON, harness, monorepoBridge, shown, withSpecs } from "./fixtures";

afterEach(() => {
  vi.useRealTimers();
});

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("GeneratorCache", () => {
  it("max-age reuses a fresh value and refetches an old one", async () => {
    vi.useFakeTimers();
    const cache = new GeneratorCache();
    let calls = 0;
    const fetch = async () => ++calls;
    const policy: Fig.Cache = { strategy: "max-age", ttl: 1_000 };
    expect(await cache.run("k", policy, fetch, () => undefined)).toBe(1);
    expect(await cache.run("k", policy, fetch, () => undefined)).toBe(1);
    vi.advanceTimersByTime(1_001);
    expect(await cache.run("k", policy, fetch, () => undefined)).toBe(2);
  });

  it("max-age without a ttl still expires", async () => {
    vi.useFakeTimers();
    const cache = new GeneratorCache();
    let calls = 0;
    const policy = { strategy: "max-age" } as Fig.Cache;
    await cache.run(
      "k",
      policy,
      async () => ++calls,
      () => undefined,
    );
    vi.advanceTimersByTime(DEFAULT_MAX_AGE_MS + 1);
    expect(
      await cache.run(
        "k",
        policy,
        async () => ++calls,
        () => undefined,
      ),
    ).toBe(2);
  });

  it("stale-while-revalidate answers at once with the old value and reports the new one", async () => {
    const cache = new GeneratorCache();
    const policy: Fig.Cache = { strategy: "stale-while-revalidate" };
    const updates: string[] = [];
    expect(
      await cache.run(
        "k",
        policy,
        async () => "v1",
        (value) => updates.push(value),
      ),
    ).toBe("v1");
    let release: (value: string) => void = () => undefined;
    const slow = new Promise<string>((resolve) => {
      release = resolve;
    });
    expect(
      await cache.run(
        "k",
        policy,
        () => slow,
        (value) => updates.push(value),
      ),
    ).toBe("v1");
    release("v2");
    await settle();
    expect(updates).toEqual(["v2"]);
    expect(
      await cache.run(
        "k",
        { strategy: "stale-while-revalidate", ttl: 60_000 },
        async () => "v3",
        () => undefined,
      ),
    ).toBe("v2");
  });
});

describe("triggers", () => {
  it.each<[Fig.Trigger | undefined, string, string, boolean, boolean]>([
    [undefined, "a", "ab", false, false],
    [undefined, "a", "ab", true, true],
    ["/", "src/a", "src/ab", false, false],
    ["/", "src/", "src", false, true],
    [{ on: "change" }, "a", "ab", false, true],
    [{ on: "threshold", length: 2 }, "abc", "ab", false, true],
    [{ on: "threshold", length: 2 }, "ab", "abc", false, false],
    [{ on: "match", string: ["x", "y"] }, "x", "z", false, true],
    [{ on: "match", string: "x" }, "a", "b", false, false],
    [
      () => {
        throw new Error("bad trigger");
      },
      "a",
      "b",
      false,
      true,
    ],
  ])("%j: %j after %j (debounced %j) → %j", (trigger, next, previous, debounced, expected) => {
    expect(shouldRetrigger(trigger, next, previous, debounced)).toBe(expected);
  });
});

describe("fuzzy matching", () => {
  it("scores word beginnings and consecutive runs", () => {
    expect(fuzzyMatch("test", "test")).toEqual({ score: 0, indexes: [0, 1, 2, 3] });
    expect(fuzzyMatch("fs", "Fuzzy Search")).toEqual({ score: -16, indexes: [0, 6] });
    expect(fuzzyMatch("mr", "MeshRenderer.cpp")?.score).toBe(-18);
    expect(fuzzyMatch("mr", "Monitor.cpp")?.score).toBe(-6009);
    expect(fuzzyMatch("xyz", "abc")).toBeNull();
  });

  it("bounds its work on names with many word beginnings (review M14)", () => {
    // Every `a` starts a word and the `b` can never be placed well, so the strict pass would try
    // every way of placing the `a`s (about 1.7 s here before the bound, doubling with each word).
    const target = `${"a ".repeat(28)}xb`;
    const started = performance.now();
    const match = fuzzyMatch(`${"a".repeat(14)}b`, target);
    expect(performance.now() - started).toBeLessThan(100);
    // Still a match, scored as one without a good placement.
    expect(match?.indexes).toHaveLength(15);
    expect(match?.score).toBeLessThan(-1000);
  });
});

describe("generators through the core", () => {
  it("runs scripts in the working directory and custom generators in the shell's", async () => {
    const h = harness();
    await h.typeOut("nr ");
    expect(h.bridge.callsTo("process.run").find((call) => call.executable === "bash")).toMatchObject({
      cwd: MONO,
      timeoutMs: 5_000,
    });
    await h.typeOut("pnpm ", "");
    // generateSpec's executeCommand gets no directory: the shell's applies.
    const bashRuns = h.bridge.callsTo("process.run").filter((call) => call.executable === "bash");
    expect(bashRuns.map((call) => call.cwd)).toEqual([MONO, undefined, MONO]);
  });

  it("uses the scriptTimeout setting as a minimum", async () => {
    const bridge = monorepoBridge();
    bridge.settings = { "autocomplete.scriptTimeout": 9_000 };
    const h = harness(bridge);
    await h.typeOut("nr ");
    expect(bridge.callsTo("process.run").find((call) => call.executable === "bash")?.timeoutMs).toBe(9_000);
  });

  it("shows a stale-while-revalidate result at once and updates it when the refetch lands", async () => {
    const h = harness();
    await h.typeOut("nr ");
    expect(shown(h.core).slice(0, 4)).toEqual(["build", "dev", "lint", "test"]);
    let release: () => void = () => undefined;
    h.bridge.onProcess(
      /^bash -c until/,
      () =>
        new Promise((resolve) => {
          release = () => resolve({ stdout: JSON.stringify({ scripts: { deploy: "x" } }) });
        }),
    );
    h.bridge.type("");
    await h.typeOut("nr ");
    expect(shown(h.core).slice(0, 4)).toEqual(["build", "dev", "lint", "test"]);
    release();
    await settle();
    await h.idle();
    expect(shown(h.core)[0]).toBe("deploy");
  });

  it("does not leak one spec's filterTemplateSuggestions into another's filepaths", async () => {
    const specs = {
      mdonly: {
        name: "mdonly",
        args: {
          generators: {
            template: "filepaths",
            filterTemplateSuggestions: (items) => items.filter((s) => String(s.name).endsWith(".md")),
          },
        },
      } satisfies Fig.Spec,
      anyfile: { name: "anyfile", args: { template: "filepaths" } } satisfies Fig.Spec,
    };
    const h = harness(monorepoBridge(), withSpecs(specs));
    await h.typeOut("mdonly ");
    expect(shown(h.core)).toEqual(["README.md"]);
    await h.typeOut("anyfile ", "");
    expect(shown(h.core)).toContain("package.json");
    expect(shown(h.core)).toContain("apps/");
  });

  it("debounces generators of debounced arguments and re-runs them on every key", async () => {
    vi.useFakeTimers();
    const spec: Fig.Spec = {
      name: "search",
      args: { debounce: true, generators: { script: (tokens) => ["lookup", tokens.at(-1) ?? ""], splitOn: "\n" } },
    };
    const bridge = monorepoBridge().onProcess(
      (params) => params.executable === "lookup",
      (params) => ({
        stdout: `${params.args[0]}-result`,
      }),
    );
    const h = harness(bridge, {
      importSpec: async () => ({ default: spec }),
      loadIndex: async () => ({ completions: ["search"], diffVersionedCompletions: [] }),
    });
    await vi.runAllTimersAsync();
    for (const line of ["s", "se", "sea", "sear", "searc", "search", "search ", "search a", "search ab"]) {
      bridge.type(line);
      await vi.advanceTimersByTimeAsync(50);
    }
    expect(bridge.processRuns().filter((run) => run.startsWith("lookup"))).toEqual([]);
    await vi.advanceTimersByTimeAsync(200);
    // Runs superseded within the debounce never start.
    expect(bridge.processRuns().filter((run) => run.startsWith("lookup"))).toEqual(["lookup ab"]);
    await vi.runAllTimersAsync();
    expect(shown(h.core)).toEqual(["ab-result"]);
  });

  it("answers the bundled ai() generator without running fig", async () => {
    const h = harness();
    await h.typeOut('git commit -m "');
    expect(h.bridge.processRuns().some((run) => run.startsWith("fig"))).toBe(false);
    expect(h.bridge.unmatchedProcesses.some((run) => run.executable === "fig")).toBe(false);
  });

  it("lists a directory only through fs.list, never with ls", async () => {
    const h = harness(monorepoBridge(), {}, HOME);
    await h.typeOut("cat Sites/");
    expect(h.bridge.callsTo("fs.list").map((call) => call.path)).toContain(`${HOME}/Sites/`);
    expect(h.bridge.processRuns().some((run) => run.startsWith("ls"))).toBe(false);
  });

  it("lists sibling subcommands for the help template, and replaces what was typed", async () => {
    const h = harness();
    await h.typeOut("croc help ");
    const state = h.core.getState();
    expect(state.suggestions.filter((s) => s.type === "special").map((s) => s.names[0])).toEqual(
      expect.arrayContaining(["send", "relay"]),
    );
    expect(state.suggestions.some((s) => s.names[0] === "help" || s.names[0] === "h")).toBe(false);
    await h.typeOut("croc help se", "croc help ");
    await h.press("insertSelected");
    // UI doc §4.4 says special entries delete nothing, which would leave `sesend`.
    expect(h.bridge.inserts()).toEqual(["nd"]);
  });

  it("lists nothing for a directory that cannot be read", async () => {
    const h = harness();
    await h.typeOut("cat nowhere/");
    expect(h.core.getState().suggestions).toEqual([]);
  });
});

describe("specs", () => {
  it("falls back to file completion for a command without a spec", async () => {
    const h = harness();
    await h.typeOut("unknowncmd --flag ");
    expect(shown(h.core)).toEqual([
      "apps/",
      "docs/",
      "node_modules/",
      "package.json",
      "packages/",
      "pnpm-lock.yaml",
      "README.md",
      "scripts/",
      ".changeset/",
      ".git/",
      ".github/",
      ".husky/",
      "../",
    ]);
  });

  it("falls back to file completion after a word the parser cannot place", async () => {
    const h = harness();
    await h.typeOut("cd apps notanarg ");
    expect(shown(h.core)).toContain("package.json");
  });

  it("completes file names after a redirection", async () => {
    const h = harness();
    await h.typeOut("git log > R");
    expect(shown(h.core)).toEqual(["README.md"]);
  });

  it("stays hidden for commands in autocomplete.disableForCommands", async () => {
    const bridge = monorepoBridge();
    bridge.settings = { "autocomplete.disableForCommands": ["git"] };
    const h = harness(bridge);
    await h.typeOut("git ch");
    expect(h.core.getState()).toMatchObject({ visible: false, suggestions: [] });
  });

  it("gives up on a spec after 5 s and completes files meanwhile", async () => {
    vi.useFakeTimers();
    const h = harness(monorepoBridge(), { ...withSpecs({}), importSpec: () => new Promise(() => undefined) });
    for (const line of ["s", "sl", "slo", "slow", "slow "]) {
      h.bridge.type(line);
      await vi.advanceTimersByTimeAsync(10);
    }
    await vi.advanceTimersByTimeAsync(5_000);
    await vi.runAllTimersAsync();
    expect(shown(h.core)).toContain("README.md");
  });

  it("uses a slow spec once it has loaded, instead of the files it fell back to (review L18)", async () => {
    vi.useFakeTimers();
    let release: () => void = () => undefined;
    const slow = new Promise<unknown>((resolve) => {
      release = () => resolve({ default: { name: "slow", subcommands: [{ name: "start" }, { name: "stop" }] } });
    });
    const h = harness(monorepoBridge(), {
      ...withSpecs({}),
      importSpec: (name) => (name === "slow" ? slow : new Promise(() => undefined)),
    });
    for (const line of ["s", "sl", "slo", "slow", "slow "]) {
      h.bridge.type(line);
      await vi.advanceTimersByTimeAsync(10);
    }
    await vi.advanceTimersByTimeAsync(5_000);
    await vi.runAllTimersAsync();
    expect(shown(h.core)).toContain("README.md");
    release();
    await vi.runAllTimersAsync();
    // The line is parsed again with the spec, and so is the rest of the word.
    expect(shown(h.core)).toEqual(["start", "stop"]);
    h.bridge.type("slow s");
    await vi.runAllTimersAsync();
    expect(shown(h.core)).toEqual(["start", "stop"]);
  });

  it("loads diff-versioned specs for the installed version", async () => {
    const bridge = monorepoBridge().onProcess("infracost --version", { stdout: "Infracost v0.9.24" });
    const h = harness(bridge);
    await h.typeOut("infracost ");
    expect(bridge.processRuns()).toContain("infracost --version");
    expect(shown(h.core)).toContain("breakdown");
  });

  it("completes command names in the first word with firstTokenCompletion", async () => {
    const bridge = monorepoBridge().onProcess(/^zsh -lic for key in/, { stdout: "git\ngrep\ngzip\nls" });
    bridge.settings = { "autocomplete.firstTokenCompletion": true };
    const h = harness(bridge);
    await h.typeOut("g");
    expect(shown(h.core)).toEqual(["git", "grep", "gzip"]);
  });

  it("expands shell aliases before parsing", async () => {
    const h = harness();
    h.bridge.updateSession({ aliases: "g=git\ngco='git checkout'" });
    await h.typeOut("gco ");
    expect(shown(h.core)[0]).toBe("main");
  });

  it("follows git's own aliases", async () => {
    const bridge = monorepoBridge().onProcess("git config --get alias.co", { stdout: "checkout\n" });
    const h = harness(bridge);
    await h.typeOut("git co ");
    expect(shown(h.core)[0]).toBe("main");
  });

  it("keeps parsing the line after a repeated option (review H8)", async () => {
    const bridge = monorepoBridge().onProcess(/^docker images --format/, {
      stdout: "ubuntu 1MB latest id1\nalpine 2MB latest id2",
    });
    const h = harness(bridge);
    await h.typeOut("docker run -e A=1 -e B=2 ub");
    expect(shown(h.core)).toEqual(["ubuntu"]);
    await h.typeOut("git -c a=b -c c=d ch", "");
    expect(shown(h.core)).toEqual(expect.arrayContaining(["checkout", "cherry-pick"]));
    await h.typeOut("curl -H a:b -H c:d --ver", "");
    expect(shown(h.core)).toEqual(expect.arrayContaining(["-v, --verbose"]));
    // The second -e is an option again, not the pattern argument (the next one is still the pattern).
    await h.typeOut("grep -e x -e y ", "");
    expect(h.core.getState().argument?.name).toBe("search pattern");
  });

  it("still hides an option that may not be given again", async () => {
    const spec: Fig.Spec = {
      name: "rep",
      options: [{ name: "-e", args: { name: "pattern" } }, { name: "-n" }, { name: "-v", isRepeatable: true }],
      args: { name: "file" },
    };
    const h = harness(monorepoBridge(), withSpecs({ rep: spec }));
    await h.typeOut("rep -e a -e b -v -");
    expect(shown(h.core)).toEqual(["-n", "-v"]);
    await h.typeOut("rep -e a -e b -v x", "rep -e a -e b -v -");
    expect(h.core.getState().argument?.name).toBe("file");
  });

  it("checks the package.json fixture is what the traces assume", () => {
    expect(JSON.parse(PACKAGE_JSON).scripts).toHaveProperty("build");
  });
});
