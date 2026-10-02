import { TimeoutError, isObject, withTimeout } from "../utils";
import { convertSubcommand } from "./convert";
import { type ExecuteCommand, type SpecLocation, type Subcommand, serializeLocation } from "./types";
import { applyVersionDiffs, extractVersion } from "./versions";

export interface SpecIndex {
  completions: string[];
  diffVersionedCompletions: string[];
}

export class MissingSpecError extends Error {
  constructor(name: string) {
    super(`No completion spec for ${name}`);
    this.name = "MissingSpecError";
  }
}

export class DisabledSpecError extends Error {
  constructor(name: string) {
    super(`Completion is disabled for ${name}`);
    this.name = "DisabledSpecError";
  }
}

export interface SpecLoaderOptions {
  importSpec: (name: string) => Promise<unknown>;
  loadIndex: () => Promise<SpecIndex>;
  /** Runs `<cli> --version` (or a spec's `getVersionCommand`) for versioned specs. */
  executeCommand: () => ExecuteCommand;
  disabledCommands: () => readonly string[];
  /**
   * A load that timed out has finished after all. Whatever was parsed without the spec (file
   * completion, cached per command prefix) is out of date.
   */
  onLateLoad?: () => void;
}

const LOAD_TIMEOUT_MS = 5_000;
/** How long a failed load is remembered, so an unknown command does not re-import on every key. */
const FAILURE_TTL_MS = 30_000;
const MAX_CACHED_SPECS = 100;

/** Specs worth loading before the first keystroke: upstream's most used, without Amazon's own. */
export const COMMON_SPECS = [
  "git",
  "cd",
  "ls",
  "npm",
  "pnpm",
  "yarn",
  "npx",
  "node",
  "docker",
  "brew",
  "ssh",
  "cat",
  "rm",
  "mv",
  "cp",
  "mkdir",
  "grep",
  "curl",
  "make",
  "code",
  "python",
];

export class SpecLoader {
  private index: Promise<{ names: Set<string>; diffVersioned: Set<string> }> | null = null;
  private readonly specs = new Map<string, Promise<Subcommand>>();
  private readonly failures = new Map<string, number>();
  private readonly cliVersions = new Map<string, string | undefined>();
  /** Loads that timed out and are still running. */
  private readonly lateLoads = new Set<string>();

  constructor(private readonly options: SpecLoaderOptions) {}

  /** Loads and converts a spec. Rejects after 5 s, but the load continues and is reused next time. */
  load(location: SpecLocation): Promise<Subcommand> {
    if (this.options.disabledCommands().includes(location.name)) {
      return Promise.reject(new DisabledSpecError(location.name));
    }
    if (location.type === "local") {
      // Project-local specs would need a file read the bridge does not offer.
      return Promise.reject(new MissingSpecError(location.name));
    }
    const key = serializeLocation(location);
    const failedAt = this.failures.get(key);
    if (failedAt !== undefined && Date.now() - failedAt < FAILURE_TTL_MS) {
      return Promise.reject(new MissingSpecError(location.name));
    }
    let pending = this.specs.get(key);
    if (pending === undefined) {
      pending = this.loadUncached(location.name);
      this.specs.set(key, pending);
      pending.catch(() => {
        this.specs.delete(key);
        this.failures.set(key, Date.now());
      });
      if (this.specs.size > MAX_CACHED_SPECS) {
        const oldest = this.specs.keys().next().value;
        if (oldest !== undefined) {
          this.specs.delete(oldest);
        }
      }
    }
    const loading = pending;
    const result = withTimeout(LOAD_TIMEOUT_MS, loading);
    result.catch((error: unknown) => {
      if (error instanceof TimeoutError && !this.lateLoads.has(key)) {
        this.lateLoads.add(key);
        loading.then(
          () => {
            this.lateLoads.delete(key);
            this.options.onLateLoad?.();
          },
          () => this.lateLoads.delete(key),
        );
      }
    });
    return result;
  }

  /** Loads specs ahead of use, one at a time, ignoring failures. */
  async preload(names: readonly string[], stop: () => boolean): Promise<void> {
    for (const name of names) {
      if (stop()) {
        return;
      }
      await this.load({ type: "global", name }).catch(() => undefined);
    }
  }

  /** Forgets failures, e.g. after the user installed a spec. */
  clearFailures(): void {
    this.failures.clear();
  }

  private getIndex(): Promise<{ names: Set<string>; diffVersioned: Set<string> }> {
    if (this.index === null) {
      this.index = this.options
        .loadIndex()
        .then((index) => ({
          names: new Set(Array.isArray(index.completions) ? index.completions : []),
          diffVersioned: new Set(Array.isArray(index.diffVersionedCompletions) ? index.diffVersionedCompletions : []),
        }))
        .catch(() => {
          this.index = null;
          return { names: new Set<string>(), diffVersioned: new Set<string>() };
        });
    }
    return this.index;
  }

  private async loadUncached(name: string): Promise<Subcommand> {
    const index = await this.getIndex();
    // Names missing from the index are still tried: user specs may not be listed in it.
    const module = await this.options.importSpec(index.diffVersioned.has(name) ? `${name}/index` : name);
    const spec = await this.resolve(module, name);
    return convertSubcommand(spec);
  }

  private async resolve(module: unknown, name: string): Promise<Fig.Subcommand> {
    const exported = isObject(module) ? module.default : undefined;
    if (isObject(exported)) {
      return exported as unknown as Fig.Subcommand;
    }
    if (typeof exported !== "function") {
      throw new MissingSpecError(name);
    }
    const version = await this.cliVersion(module as Record<string, unknown>, name);
    const result: unknown = await (exported as (version?: string) => unknown)(version);
    if (isObject(result) && typeof result.versionedSpecPath === "string") {
      const file = await this.options.importSpec(result.versionedSpecPath);
      if (!isObject(file) || !isObject(file.default) || !isObject(file.versions)) {
        throw new MissingSpecError(result.versionedSpecPath);
      }
      const target = typeof result.version === "string" ? result.version : version;
      return applyVersionDiffs(
        file.default as unknown as Fig.Subcommand,
        file.versions as unknown as Fig.VersionDiffMap,
        target,
      );
    }
    if (isObject(result)) {
      return result as unknown as Fig.Subcommand;
    }
    throw new MissingSpecError(name);
  }

  private async cliVersion(module: Record<string, unknown>, name: string): Promise<string | undefined> {
    if (this.cliVersions.has(name)) {
      return this.cliVersions.get(name);
    }
    let version: string | undefined;
    try {
      const executeCommand = this.options.executeCommand();
      if (typeof module.getVersionCommand === "function") {
        const output: unknown = await (module.getVersionCommand as Fig.GetVersionCommand)(executeCommand);
        version = typeof output === "string" ? (extractVersion(output) ?? output) : undefined;
      } else {
        version = extractVersion((await executeCommand({ command: name, args: ["--version"] })).stdout);
      }
    } catch {
      version = undefined;
    }
    this.cliVersions.set(name, version);
    return version;
  }
}
