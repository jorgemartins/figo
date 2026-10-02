/**
 * When suggestions were last inserted, per root command and first name (engine doc §6.4). Picking
 * `install` under `pnpm` lifts every `pnpm` suggestion named `install` above the default priority.
 */

export interface KeyValueStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

const STORAGE_KEY = "figo.recency";

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
    this.index = { ...this.index, [rootCommand]: { ...this.index[rootCommand], [name]: at } };
    try {
      this.storage.setItem(STORAGE_KEY, JSON.stringify(this.index));
    } catch {
      // Storage full or unavailable: recency just does not persist.
    }
  }
}
