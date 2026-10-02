/**
 * Shell history: read once, lazily, from a login shell, plus every command seen in `postExec`
 * during this run. Used by history mode (ctrl+r) and the `history` template.
 */
import type { Item } from "../suggestions/types";
import { hasControlCharacters } from "../utils";

export type RunCommand = (executable: string, args: string[]) => Promise<string>;

const DONE_SOURCING = "\x1b]697;DoneSourcing\x07";

/** The command each shell needs to print its history, oldest entry first (fish prints newest first). */
function historyCommand(shell: string): { command: string; newestFirst: boolean } | null {
  switch (shell) {
    case "zsh":
      return { command: "fc -R; fc -ln 1", newestFirst: false };
    case "bash":
      return { command: "fc -ln 1", newestFirst: false };
    case "fish":
      return { command: "history search", newestFirst: true };
    default:
      return null;
  }
}

export async function readShellHistory(
  run: RunCommand,
  shell: string,
  shellPath: string,
  customCommand: string | undefined,
): Promise<string[]> {
  let output: string;
  let newestFirst = false;
  if (customCommand) {
    output = await run("zsh", ["-c", customCommand]);
  } else {
    const spec = historyCommand(shell);
    if (spec === null) {
      return [];
    }
    newestFirst = spec.newestFirst;
    // Interactive login shell, so the user's rc files set HISTFILE and friends.
    output = await run(shellPath, ["-lic", spec.command]);
  }
  const marker = output.lastIndexOf(DONE_SOURCING);
  if (marker !== -1) {
    output = output.slice(marker + DONE_SOURCING.length);
  }
  const lines = output
    .split("\n")
    .map((line) => (shell === "bash" && !customCommand ? line.replace(/^\s+/, "") : line).replace(/\s+$/, ""))
    .filter((line) => line !== "");
  return newestFirst ? lines.reverse() : lines;
}

export class History {
  /** Per shell (zsh, bash, fish, or the custom command), oldest first. */
  private readonly shellEntries = new Map<string, string[]>();
  private readonly loading = new Map<string, Promise<void>>();
  private readonly sessionEntries: string[] = [];
  /** Bumped whenever entries change, so dependants can tell their snapshot is stale. */
  version = 0;

  isLoaded(source: string): boolean {
    return this.shellEntries.has(source);
  }

  /** Reads a source's history once; later calls reuse it. A failed read counts as empty. */
  ensureLoaded(source: string, read: () => Promise<string[]>): Promise<void> {
    if (this.shellEntries.has(source)) {
      return Promise.resolve();
    }
    let pending = this.loading.get(source);
    if (pending === undefined) {
      pending = read()
        .catch(() => [] as string[])
        .then((entries) => {
          this.shellEntries.set(source, entries);
          this.loading.delete(source);
          this.version += 1;
        });
      this.loading.set(source, pending);
    }
    return pending;
  }

  add(command: string): void {
    const text = command.replace(/\s+$/, "");
    if (text !== "") {
      this.sessionEntries.push(text);
      this.version += 1;
    }
  }

  /** Every entry of a source plus this run's commands, most recent first. */
  entries(source: string): string[] {
    return [...this.sessionEntries].reverse().concat([...(this.shellEntries.get(source) ?? [])].reverse());
  }
}

function firstWord(text: string): string {
  return text.split(" ", 1)[0] ?? "";
}

/**
 * History mode (engine doc §7): every past command line starting with `prefix` (the buffer up to
 * the token being typed) offers its remainder. Lines are most recent first; a remainder whose
 * first word recurs is ranked above 75.
 */
export function historyItems(entries: readonly string[], prefix: string): Item[] {
  const remainders: string[] = [];
  const counts = new Map<string, number>();
  for (const entry of entries) {
    if (!entry.startsWith(prefix)) {
      continue;
    }
    const rest = entry.slice(prefix.length).replace(/\s+$/, "");
    // A multi-line entry cannot be typed: its first newline would run the line there and then.
    if (rest === "" || hasControlCharacters(rest)) {
      continue;
    }
    remainders.push(rest);
    const word = firstWord(rest);
    if (word) {
      counts.set(word, (counts.get(word) ?? 0) + 1);
    }
  }
  return [...new Set(remainders)].map((rest) => {
    const count = counts.get(firstWord(rest)) ?? 0;
    return {
      type: "history",
      names: [rest],
      insertValue: rest,
      icon: "📚",
      description: "past command",
      priority: count > 1 ? 75 + Math.min(count, 10) / 10 : 50,
    };
  });
}
