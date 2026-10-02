/**
 * When suggestions were last inserted, per root command and first name (engine doc §6.4). Picking
 * `install` under `pnpm` lifts every `pnpm` suggestion named `install` above the default priority.
 */

export interface KeyValueStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

const STORAGE_KEY = "figo.recency";
/** Root commands remembered; the one used longest ago goes first. */
export const MAX_RECENCY_COMMANDS = 100;
/** Names remembered per root command. The whole index is rewritten on every pick, so it stays small. */
export const MAX_RECENCY_NAMES = 50;

/** The `limit` entries with the highest values. */
function newest(entries: Record<string, number>, limit: number): Record<string, number> {
  const pairs = Object.entries(entries);
  return pairs.length <= limit ? entries : Object.fromEntries(pairs.sort((a, b) => b[1] - a[1]).slice(0, limit));
}

export function memoryStorage(): KeyValueStorage {
  const values = new Map<string, string>();
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => {
      values.set(key, value);
    },
  };
}

export class RecencyIndex {
  private index: Record<string, Record<string, number>>;

  constructor(private readonly storage: KeyValueStorage) {
    this.index = {};
    try {
      const parsed: unknown = JSON.parse(storage.getItem(STORAGE_KEY) ?? "{}");
      if (typeof parsed === "object" && parsed !== null) {
        this.index = parsed as Record<string, Record<string, number>>;
      }
    } catch {
      this.index = {};
    }
  }

  lastUsed(rootCommand: string, name: string): number | undefined {
    const value = this.index[rootCommand]?.[name];
    return typeof value === "number" ? value : undefined;
  }

  record(rootCommand: string, name: string, at = Date.now()): void {
    if (name.includes("↪") || rootCommand === "") {
      return;
    }
    const names = newest({ ...this.index[rootCommand], [name]: at }, MAX_RECENCY_NAMES);
    let index = { ...this.index, [rootCommand]: names };
    if (Object.keys(index).length > MAX_RECENCY_COMMANDS) {
      const lastPicks = Object.fromEntries(
        Object.entries(index).map(([command, picks]) => [command, Math.max(...Object.values(picks ?? {}))]),
      );
      const kept = newest(lastPicks, MAX_RECENCY_COMMANDS);
      index = Object.fromEntries(Object.entries(index).filter(([command]) => command in kept));
    }
    this.index = index;
    try {
      this.storage.setItem(STORAGE_KEY, JSON.stringify(this.index));
    } catch {
      // Storage full or unavailable: recency just does not persist.
    }
  }
}
