/**
 * The worked traces of the engine doc (§11), end to end through createCore with real specs from
 * specs/dist and the fake bridge: visible names, order, types and the inserted bytes.
 */
import { describe, expect, it } from "vitest";
import { HOME, MONO, harness, monorepoBridge, shown, shownTypes } from "./fixtures";

describe("11.1 cd ", () => {
  it("lists the folders of the working directory, dotfolders last, then ../", async () => {
    const { core, bridge, typeOut, press } = harness();
    await typeOut("cd ");
    expect(shown(core)).toEqual([
      "apps/",
      "docs/",
      "node_modules/",
      "packages/",
      "scripts/",
      ".changeset/",
      ".git/",
      ".github/",
      ".husky/",
      "../",
    ]);
    expect(new Set(shownTypes(core))).toEqual(new Set(["folder"]));
    // The hidden `-` and `~` of the cd spec are not shown for an empty query.
    expect(bridge.callsTo("fs.list")).toEqual([{ sessionId: "session-1", path: `${MONO}/` }]);
    expect(core.getState().suggestions[0]?.icon).toBe(`fig://path${MONO}/apps/`);

    await press("insertSelected");
    expect(bridge.inserts()).toEqual(["apps/"]);
  });
});

describe("11.2 cd Sites/ typed letter by letter from ~", () => {
  it("filters fuzzily without re-listing, offers to run on an exact match, then lists the folder", async () => {
    const { core, bridge, typeOut, press } = harness(monorepoBridge(), {}, HOME);
    await typeOut("cd S");
    // Prefix matches first (alphabetical among equals), then fuzzy ones.
    expect(shown(core)).toEqual(["Scripts/", "Sites/", "Desktop/", "Documents/", "Applications/"]);
    await typeOut("cd Si", "cd S");
    expect(shown(core)).toEqual(["Sites/", "Scripts/"]);
    expect(core.getState().suggestions[0]?.match).toEqual({ nameIndex: 0, ranges: [[0, 2]] });

    await typeOut("cd Sites", "cd Si");
    expect(shown(core)).toEqual(["Sites", "Sites/"]);
    expect(shownTypes(core)).toEqual(["auto-execute", "folder"]);
    expect(core.getState().suggestions[0]?.description).toBe("folder");
    // Typing within the word never re-listed the directory.
    expect(bridge.callsTo("fs.list").map((call) => call.path)).toEqual([`${HOME}/`]);

    await press("insertSelected");
    expect(bridge.inserts()).toEqual(["\n"]);

    await typeOut("cd Sites/", "cd Sites");
    expect(bridge.callsTo("fs.list").map((call) => call.path)).toEqual([`${HOME}/`, `${HOME}/Sites/`]);
    expect(shown(core)).toEqual(["↪", "figo/", "mono/", ".something/", "../"]);
    expect(shownTypes(core)).toEqual(["auto-execute", "folder", "folder", "folder", "folder"]);
    expect(core.getState().suggestions[0]?.description).toBe("Enter the current directory");

    await press("navigateDown");
    await press("insertSelected");
    expect(bridge.inserts().at(-1)).toBe("figo/");
  });
});

describe("11.3 git checkout ", () => {
  it("shows the current branch, branches, -, tags, files and then options", async () => {
    const { core, bridge, typeOut, press } = harness();
    await typeOut("git checkout ");
    expect(bridge.processRuns()).toEqual(
      expect.arrayContaining([
        "git help -a",
        "git --no-optional-locks branch -a --no-color --sort=-committerdate",
        "git --no-optional-locks tag --list --sort=-committerdate",
      ]),
    );
    const names = shown(core);
    expect(names.slice(0, 21)).toEqual([
      "main",
      "feature/login",
      "fix/typo",
      "HEAD",
      "release",
      "-",
      "v2.0.0",
      "v1.0.0",
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
    const state = core.getState();
    expect(state.suggestions[0]).toMatchObject({ icon: "⭐️", description: "Current branch" });
    expect(state.suggestions[1]).toMatchObject({ description: "Branch" });
    expect(state.suggestions[4]).toMatchObject({ names: ["release"], description: "Remote branch" });
    expect(state.suggestions[6]).toMatchObject({ icon: "🏷️" });

    // Options follow in localeCompare order of their first name: every `--long` before `-x`.
    const options = names.slice(21);
    expect(options[0]).toBe("--conflict");
    expect(options.indexOf("--recurse-submodules")).toBeLessThan(options.indexOf("-2, --ours"));
    expect(options.slice(options.indexOf("-2, --ours"), options.indexOf("-2, --ours") + 5)).toEqual([
      "-2, --ours",
      "-3, --theirs",
      "-b",
      "-B",
      "-d, --detach",
    ]);
    expect(options).not.toContain("--");
    expect(new Set(shownTypes(core).slice(21))).toEqual(new Set(["option"]));

    await press("insertSelected");
    expect(bridge.inserts()).toEqual(["main"]);
  });

  it("filters fuzzily (prefix matches first) when typing", async () => {
    const { core, typeOut } = harness();
    await typeOut("git checkout fe");
    expect(shown(core).slice(0, 1)).toEqual(["feature/login"]);
    expect(core.getState().suggestions[0]?.match.ranges).toEqual([[0, 2]]);
  });
});

describe('11.4 git commit -m "x" --am', () => {
  it("offers only --amend with prefix filtering", async () => {
    const { core, bridge, typeOut, press } = harness();
    await typeOut('git commit -m "x" --am');
    expect(shown(core)).toEqual(["--amend"]);
    expect(shownTypes(core)).toEqual(["option"]);
    await press("insertSelected");
    expect(bridge.inserts()).toEqual(["end"]);
  });

  it("puts a run-it twin on top once the option is typed exactly", async () => {
    const { core, bridge, typeOut, press } = harness();
    await typeOut('git commit -m "x" --amend');
    expect(shown(core)).toEqual(["--amend", "--amend"]);
    expect(shownTypes(core)).toEqual(["auto-execute", "option"]);
    await press("insertSelected");
    expect(bridge.inserts()).toEqual(["\n"]);
  });

  it("with fuzzy search on, fuzzy matches follow the prefix match", async () => {
    const bridge = monorepoBridge();
    bridge.settings = { "autocomplete.fuzzySearch": true };
    const { core, typeOut } = harness(bridge);
    await typeOut('git commit -m "x" --am');
    // The doc lists --allow-empty(-message); --pathspec-from-file matches too (- - a … m), and
    // --allow-empty-message outranks --allow-empty because its `m` starts a word.
    expect(shown(core)).toEqual(["--amend", "--allow-empty-message", "--allow-empty", "--pathspec-from-file"]);
    expect(core.getState().suggestions[1]?.match).toEqual({
      nameIndex: 0,
      ranges: [
        [0, 3],
        [14, 15],
      ],
    });
  });
});

describe("11.5 nr ", () => {
  it("lists package.json scripts, the - shortcut and the help option", async () => {
    const { core, bridge, typeOut, press } = harness();
    await typeOut("nr ");
    expect(shown(core)).toEqual(["build", "dev", "lint", "test", "-", "-h, --help"]);
    expect(shownTypes(core)).toEqual(["arg", "arg", "arg", "arg", "shortcut", "option"]);
    expect(core.getState().suggestions[0]).toMatchObject({ icon: "fig://icon?type=npm", description: "turbo build" });
    const script = bridge.callsTo("process.run").find((call) => call.executable === "bash");
    expect(script).toMatchObject({ cwd: MONO, args: ["-c", expect.stringContaining("cat package.json")] });

    await press("insertSelected");
    expect(bridge.inserts()).toEqual(["build"]);
  });
});

describe("11.6 pnpm ", () => {
  it("lists scripts, then subcommands including generated node CLIs, then options", async () => {
    const { core, bridge, typeOut, press } = harness();
    await typeOut("pnpm ");
    const names = shown(core);
    expect(names.slice(0, 4)).toEqual(["build", "dev", "lint", "test"]);
    expect(names.slice(-4)).toEqual(["-C, --dir", "-h, --help", "-v, --version", "-w, --workspace-root"]);
    const subcommands = names.slice(4, -4);
    const firstNames = core
      .getState()
      .suggestions.slice(4, -4)
      .map((s) => s.names[0] ?? "");
    expect(firstNames).toEqual([...firstNames].sort((a, b) => a.localeCompare(b)));
    for (const generated of ["eslint", "prettier", "vite"]) {
      expect(subcommands).toContain(generated);
    }
    expect(subcommands).not.toContain("typescript");
    expect(subcommands.slice(0, 3)).toEqual(["add", "audit", "doctor"]);
    const install = core.getState().suggestions.find((s) => s.names[0] === "install");
    expect(install).toMatchObject({
      names: ["install", "i"],
      type: "subcommand",
      args: [{ name: "package", isOptional: true, isVariadic: true }],
    });

    // Picking `install` once makes it rank above the scripts (recency, §6.4).
    const index = core.getState().suggestions.indexOf(install as never);
    for (let i = 0; i < index; i += 1) {
      await press("navigateDown");
    }
    await press("insertSelected");
    expect(bridge.inserts()).toEqual(["install"]);
    bridge.type("");
    await typeOut("pnpm ");
    expect(shown(core)[0]).toBe("install, i");
    expect(shown(core).slice(1, 5)).toEqual(["build", "dev", "lint", "test"]);
  });
});

describe("11.7 npm run ", () => {
  it("lists scripts and then run's options", async () => {
    const { core, bridge, typeOut, press } = harness();
    await typeOut("npm ru");
    await press("insertSelected");
    // `run` takes a mandatory script, so it is inserted with a trailing space.
    expect(bridge.inserts()).toEqual(["n "]);
    await typeOut("npm run ", "npm ru");
    expect(shown(core)).toEqual([
      "build",
      "dev",
      "lint",
      "test",
      "--",
      "--if-present",
      "--ignore-scripts",
      "--script-shell",
      "--silent",
      "-w, --workspace",
      "-ws, --workspaces",
    ]);
    expect(shownTypes(core).slice(0, 5)).toEqual(["arg", "arg", "arg", "arg", "option"]);
  });
});

describe("11.8 ls -la ~/", () => {
  it("offers to run in the directory, then lists the home folder", async () => {
    const { core, bridge, typeOut, press } = harness();
    await typeOut("ls -la ~/");
    expect(bridge.callsTo("fs.list").at(-1)?.path).toBe(`${HOME}/`);
    expect(shown(core)).toEqual([
      "↪",
      "Applications/",
      "Desktop/",
      "Documents/",
      "notes.txt",
      "Scripts/",
      "Sites/",
      ".config/",
      ".zshrc",
      "../",
    ]);
    expect(shownTypes(core)).toEqual([
      "auto-execute",
      "folder",
      "folder",
      "folder",
      "file",
      "folder",
      "folder",
      "folder",
      "file",
      "folder",
    ]);
    expect(core.getState().suggestions[1]?.icon).toBe(`fig://path${HOME}/Applications/`);
    await press("insertSelected");
    expect(bridge.inserts()).toEqual(["\n"]);
  });
});

describe("11.9 docker run -it --rm ", () => {
  const images = Array.from({ length: 30 }, (_, i) => `repo${i % 20} ${i}MB tag${i} id${i}`).join("\n");

  it("lists images, then the options that are still allowed", async () => {
    const bridge = monorepoBridge().onProcess(/^docker images --format/, { stdout: images });
    const { core, typeOut, press } = harness(bridge);
    await typeOut("docker run -it --rm ");
    const names = shown(core);
    const types = shownTypes(core);
    // More than 50 entries, so images with several tags stay duplicated.
    expect(names.slice(0, 30)).toEqual(Array.from({ length: 30 }, (_, i) => `repo${i % 20}`));
    expect(types.slice(0, 30).every((type) => type === "arg")).toBe(true);
    expect(core.getState().suggestions[0]).toMatchObject({
      description: "id0@tag0 - 0MB",
      icon: "fig://icon?type=docker",
    });
    const options = names.slice(30);
    expect(options[0]).toBe("--add-host");
    expect(options).toContain("-it");
    for (const passed of ["-i, --interactive", "-t, --tty", "--rm"]) {
      expect(options).not.toContain(passed);
    }
    await press("insertSelected");
    expect(bridge.inserts()).toEqual(["repo0"]);
  });

  it("collapses same-repo images once the list is short", async () => {
    const bridge = monorepoBridge().onProcess(/^docker images --format/, { stdout: images });
    const { core, typeOut } = harness(bridge);
    await typeOut("docker run -it --rm repo1");
    // repo1 (two tags) appears once, under its run-it twin; repo10–repo19 match the prefix too.
    const repo1 = core.getState().suggestions.filter((s) => s.names[0] === "repo1");
    expect(repo1.map((s) => s.type)).toEqual(["auto-execute", "arg"]);
    expect(shown(core)).toHaveLength(12);
  });
});
