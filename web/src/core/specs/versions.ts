import { isObject, makeArray } from "../utils";

type Version = { parts: number[]; prerelease: string };

function parseVersion(text: string): Version | null {
  const match = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?/.exec(text.trim());
  if (!match) {
    return null;
  }
  return { parts: [Number(match[1]), Number(match[2]), Number(match[3])], prerelease: match[4] ?? "" };
}

export function compareVersions(a: string, b: string): number {
  const va = parseVersion(a);
  const vb = parseVersion(b);
  if (!va || !vb) {
    return a.localeCompare(b);
  }
  for (let i = 0; i < 3; i += 1) {
    const diff = (va.parts[i] ?? 0) - (vb.parts[i] ?? 0);
    if (diff !== 0) {
      return diff;
    }
  }
  if (va.prerelease === vb.prerelease) {
    return 0;
  }
  if (!va.prerelease) {
    return 1;
  }
  if (!vb.prerelease) {
    return -1;
  }
  return va.prerelease.localeCompare(vb.prerelease);
}

/** The first `x.y.z` in a program's `--version` output, e.g. `git version 2.39.5` → `2.39.5`. */
export function extractVersion(output: string): string | undefined {
  return /\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?/.exec(output)?.[0];
}

/** Index of the last version ≤ target, or the newest when there is no target or none qualifies. */
function bestVersionIndex(sorted: readonly string[], target?: string): number {
  if (target) {
    for (let i = sorted.length - 1; i >= 0; i -= 1) {
      if (compareVersions(sorted[i] ?? "", target) <= 0) {
        return i;
      }
    }
  }
  return sorted.length - 1;
}

type Named = { name?: string | string[]; remove?: boolean };

function namesOverlap(a: Named, b: Named): boolean {
  const names = new Set(makeArray(a.name));
  return makeArray(b.name).some((name) => names.has(name));
}

function mergeNamed<T extends Named>(current: T[], diffs: T[], merge: (item: T, diff: T) => T): T[] {
  const result: T[] = [];
  const used = new Set<number>();
  for (const diff of diffs) {
    const index = current.findIndex((item, i) => !used.has(i) && namesOverlap(item, diff));
    if (index === -1) {
      if (!diff.remove) {
        result.push(diff);
      }
      continue;
    }
    used.add(index);
    if (!diff.remove) {
      result.push(merge(current[index] as T, diff));
    }
  }
  current.forEach((item, i) => {
    if (!used.has(i)) {
      result.push(item);
    }
  });
  return result;
}

function mergeArgs(current: unknown, diff: unknown): Fig.Arg[] {
  const base = makeArray(current as Fig.SingleOrArray<Fig.Arg>);
  return makeArray(diff as Fig.SingleOrArray<Fig.Arg & { remove?: boolean }>)
    .filter((arg) => !(isObject(arg) && arg.remove))
    .map((arg, i) => ({ ...base[i], ...arg }));
}

function mergeOption(option: Fig.Option, diff: Fig.Option): Fig.Option {
  const merged: Fig.Option = { ...option, ...diff };
  if (diff.args !== undefined) {
    merged.args = mergeArgs(option.args, diff.args);
  }
  return merged;
}

function mergeSubcommand(spec: Fig.Subcommand, diff: Fig.Subcommand): Fig.Subcommand {
  const merged: Fig.Subcommand = { ...spec, ...diff };
  if (diff.subcommands !== undefined) {
    merged.subcommands = mergeNamed(makeArray(spec.subcommands), makeArray(diff.subcommands), mergeSubcommand);
  }
  if (diff.options !== undefined) {
    merged.options = mergeNamed(makeArray(spec.options), makeArray(diff.options), mergeOption);
  }
  if (diff.args !== undefined) {
    merged.args = mergeArgs(spec.args, diff.args);
  }
  return merged;
}

/** Applies a diff-versioned spec's version diffs, in version order, up to the best match. */
export function applyVersionDiffs(base: Fig.Subcommand, versions: Fig.VersionDiffMap, target?: string): Fig.Subcommand {
  const names = Object.keys(versions).sort(compareVersions);
  const last = bestVersionIndex(names, target);
  let spec = base;
  for (const name of names.slice(0, last + 1)) {
    spec = mergeSubcommand(spec, { ...(versions[name] as Fig.Subcommand), name: spec.name });
  }
  return spec;
}
