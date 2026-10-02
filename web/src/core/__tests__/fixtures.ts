import { createCore } from "../index";
import type { Core, CoreOptions } from "../contract";
import { FakeBridge, diskSpecs, whenIdle } from "../testing";

export const HOME = "/Users/test";
export const MONO = `${HOME}/Sites/mono`;

/** A pnpm monorepo, as assumed by the worked traces (engine doc §11). */
export const PACKAGE_JSON = JSON.stringify({
  name: "mono",
  scripts: { build: "turbo build", dev: "turbo dev", lint: "eslint .", test: "vitest" },
  devDependencies: { vite: "^5.0.0", eslint: "^9.0.0", prettier: "^3.0.0", typescript: "^5.0.0" },
});

export function monorepoBridge(): FakeBridge {
  const bridge = new FakeBridge();
  bridge
    .setDirectory(HOME, [
      "Applications/",
      "Desktop/",
      "Documents/",
      "Scripts/",
      "Sites/",
      "notes.txt",
      ".config/",
      ".zshrc",
      ".DS_Store",
    ])
    .setDirectory(`${HOME}/Sites`, ["mono/", "figo/", ".something/"])
    .setDirectory(MONO, [
      "packages/",
      "apps/",
      "scripts/",
      "docs/",
      "node_modules/",
      ".git/",
      ".github/",
      ".changeset/",
      ".husky/",
      "package.json",
      "pnpm-lock.yaml",
      "README.md",
    ])
    .setDirectory(`${MONO}/apps`, ["web/", "api/"])
    .onProcess(/^bash -c until \[\[ -f package\.json \]\]/, { stdout: PACKAGE_JSON })
    .onProcess("git help -a", {
      stdout: "See 'git help <command>'\n\nexternal commands\n   lfs\n   flow\n",
    })
    .onProcess("git --no-optional-locks branch -a --no-color --sort=-committerdate", {
      stdout:
        "* main\n  feature/login\n  fix/typo\n  remotes/origin/HEAD -> origin/main\n  remotes/origin/main\n  remotes/origin/release",
    })
    .onProcess("git --no-optional-locks tag --list --sort=-committerdate", { stdout: "v2.0.0\nv1.0.0" });
  return bridge;
}

export interface Harness {
  bridge: FakeBridge;
  core: Core;
  /** Types the line one character at a time, as a user would, waiting for the core each time. */
  typeOut(line: string, from?: string): Promise<void>;
  /** Replaces the line in one edit (a paste) and waits. */
  set(line: string): Promise<void>;
  press(action: string): Promise<void>;
  /** Lets the shell echo the last insertion back as a new edit buffer. */
  echo(): Promise<string>;
  idle(): Promise<void>;
}

export function harness(bridge = monorepoBridge(), options: CoreOptions = {}, cwd = MONO): Harness {
  const core = createCore(bridge, { ...diskSpecs(), ...options });
  bridge.startSession({ cwd, home: HOME, env: { HOME, PATH: "/usr/bin:/bin", SHELL: "/bin/zsh" } });
  const idle = () => whenIdle(core);
  return {
    bridge,
    core,
    idle,
    async typeOut(line, from = "") {
      for (let i = from.length + 1; i <= line.length; i += 1) {
        bridge.type(line.slice(0, i));
        await idle();
      }
    },
    async set(line) {
      bridge.type(line);
      await idle();
    },
    async press(action) {
      bridge.press(action);
      await idle();
    },
    async echo() {
      const { buffer } = bridge.echoLastInsert();
      await idle();
      return buffer;
    },
  };
}

/** Disk specs plus some made up for a test (looked up first). */
export function withSpecs(extra: Record<string, Fig.Spec>): CoreOptions {
  const disk = diskSpecs();
  return {
    importSpec: async (name) => (name in extra ? { default: extra[name] } : disk.importSpec?.(name)),
    loadIndex: async () => {
      const index = await (disk.loadIndex as NonNullable<CoreOptions["loadIndex"]>)();
      return { ...index, completions: [...index.completions, ...Object.keys(extra)] };
    },
  };
}

/** Moves the selection down to the first entry whose first name is `name`. */
export async function select(h: Harness, name: string): Promise<void> {
  const index = h.core.getState().suggestions.findIndex((s) => s.names[0] === name);
  if (index === -1) {
    throw new Error(`${name} is not in the list: ${shown(h.core).join(" ")}`);
  }
  while (h.core.getState().selectedIndex < index) {
    await h.press("navigateDown");
  }
}

/** What the popup shows: displayName or the names joined, as the UI renders them. */
export function shown(core: Core): string[] {
  const state = core.getState();
  return state.visible ? state.suggestions.map((s) => s.displayName ?? s.names.join(", ")) : [];
}

export function shownTypes(core: Core): string[] {
  return core.getState().suggestions.map((s) => s.type);
}
