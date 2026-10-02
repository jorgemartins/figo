/**
 * Generator result caching (`Fig.Cache`).
 *
 * - `max-age`: a value younger than `ttl` is reused; older ones are refetched and awaited.
 * - `stale-while-revalidate`: a cached value is returned at once, however old; when it is older than
 *   `ttl` (default 0) a refetch starts in the background and `onRevalidated` receives the result.
 *   Upstream awaited the refetch instead, which defeats the point.
 */

/** Upstream never expired a `max-age` entry without a `ttl`; give it a finite life instead. */
export const DEFAULT_MAX_AGE_MS = 30_000;
const MAX_ENTRIES = 500;

interface Entry {
  value?: unknown;
  hasValue: boolean;
  fetchedAt: number;
  inFlight?: Promise<unknown>;
}

export class GeneratorCache {
  private readonly entries = new Map<string, Entry>();

  async run<T>(key: string, cache: Fig.Cache, fetch: () => Promise<T>, onRevalidated: (value: T) => void): Promise<T> {
    let entry = this.entries.get(key);
    if (entry === undefined) {
      entry = { hasValue: false, fetchedAt: 0 };
      this.entries.set(key, entry);
      this.evict();
    }
    if (!entry.hasValue) {
      return (await this.refresh(entry, fetch)) as T;
    }
    const age = Date.now() - entry.fetchedAt;
    if (cache.strategy === "max-age") {
      const ttl = typeof cache.ttl === "number" ? cache.ttl : DEFAULT_MAX_AGE_MS;
      return (age < ttl ? entry.value : await this.refresh(entry, fetch)) as T;
    }
    const ttl = typeof cache.ttl === "number" ? cache.ttl : 0;
    if (age >= ttl && entry.inFlight === undefined) {
      const previous = entry.value;
      this.refresh(entry, fetch).then(
        (value) => {
          if (JSON.stringify(value) !== JSON.stringify(previous)) {
            onRevalidated(value as T);
          }
        },
        () => {
          // Keep serving the stale value.
        },
      );
    }
    return entry.value as T;
  }

  clear(): void {
    this.entries.clear();
  }

  private refresh(entry: Entry, fetch: () => Promise<unknown>): Promise<unknown> {
    if (entry.inFlight === undefined) {
      const started = Date.now();
      entry.inFlight = fetch().then(
        (value) => {
          entry.value = value;
          entry.hasValue = true;
          entry.fetchedAt = started;
          entry.inFlight = undefined;
          return value;
        },
        (error: unknown) => {
          entry.inFlight = undefined;
          throw error;
        },
      );
    }
    return entry.inFlight;
  }

  private evict(): void {
    if (this.entries.size > MAX_ENTRIES) {
      const oldest = this.entries.keys().next().value;
      if (oldest !== undefined) {
        this.entries.delete(oldest);
      }
    }
  }
}
