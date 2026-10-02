import { isObject, makeArray } from "../utils";
import type { Arg, ExecuteCommand, LoadSpec, Option, SpecLocation, Subcommand } from "./types";

function isString(value: unknown): value is string {
  return typeof value === "string";
}

function namedMap<T extends { name: string[] }>(items: readonly T[]): Map<string, T> {
  const map = new Map<string, T>();
  for (const item of items) {
    for (const name of item.name) {
      map.set(name, item);
    }
  }
  return map;
}

function toLocation(value: unknown): SpecLocation | null {
  if (!isObject(value) || typeof value.name !== "string") {
    return null;
  }
  if (value.type === "local") {
    return { type: "local", name: value.name, path: typeof value.path === "string" ? value.path : undefined };
  }
  return { type: "global", name: value.name };
}

/** Normalises what a `loadSpec` function resolves to: locations, one location, or a subcommand. */
function normalizeLoadSpecResult(result: unknown): SpecLocation[] | Subcommand | undefined {
  if (Array.isArray(result)) {
    return result.map(toLocation).filter((location): location is SpecLocation => location !== null);
  }
  if (!isObject(result)) {
    return undefined;
  }
  if ("type" in result) {
    const location = toLocation(result);
    return location ? [location] : undefined;
  }
  return convertSubcommand(result as unknown as Fig.Subcommand);
}

function convertLoadSpec(loadSpec: unknown): LoadSpec | undefined {
  if (typeof loadSpec === "string") {
    return [{ type: "global", name: loadSpec }];
  }
  if (typeof loadSpec === "function") {
    const load = loadSpec as (token: string, executeCommand: ExecuteCommand) => Promise<unknown>;
    return async (token, executeCommand) => normalizeLoadSpecResult(await load(token, executeCommand)) ?? [];
  }
  return normalizeLoadSpecResult(loadSpec);
}

function convertArg(arg: Fig.Arg): Arg {
  const { template, generators, loadSpec, ...rest } = arg;
  // Upstream drops `generators` when `template` is also set; keeping both loses nothing.
  const all: Fig.Generator[] = [
    ...(template !== undefined ? [{ template }] : []),
    ...makeArray(generators).filter(isObject),
  ];
  return { ...rest, generators: all, loadSpec: loadSpec === undefined ? undefined : convertLoadSpec(loadSpec) };
}

function convertArgs(args: Fig.SingleOrArray<Fig.Arg> | undefined): Arg[] {
  return makeArray(args).filter(isObject).map(convertArg);
}

function convertOption(option: Fig.Option): Option {
  return { ...option, name: makeArray(option.name).filter(isString), args: convertArgs(option.args) };
}

/**
 * Converts a spec node. Children and options are converted on first access: the cloud specs are
 * megabytes, and a parse only ever walks one path through them.
 */
export function convertSubcommand(spec: Fig.Subcommand): Subcommand {
  const { name, subcommands, options, args, loadSpec, ...rest } = spec;
  let children: Map<string, Subcommand> | undefined;
  let plain: Map<string, Option> | undefined;
  let persistent: Map<string, Option> | undefined;
  const convertedOptions = () => makeArray(options).filter(isObject).map(convertOption);
  return {
    ...(rest as Omit<Subcommand, "name" | "subcommands" | "options" | "persistentOptions" | "args" | "loadSpec">),
    name: makeArray(name).filter(isString),
    get subcommands() {
      children ??= namedMap(makeArray(subcommands).filter(isObject).map(convertSubcommand));
      return children;
    },
    get options() {
      plain ??= namedMap(convertedOptions().filter((option) => !option.isPersistent));
      return plain;
    },
    get persistentOptions() {
      persistent ??= namedMap(convertedOptions().filter((option) => option.isPersistent));
      return persistent;
    },
    args: convertArgs(args),
    loadSpec: loadSpec === undefined ? undefined : convertLoadSpec(loadSpec),
  };
}

const origins = new WeakMap<Subcommand, Subcommand>();

/** The spec node a derived node (`withChanges`) was made from, or the node itself. */
export function originOf(node: Subcommand): Subcommand {
  return origins.get(node) ?? node;
}

/** The same node with some fields replaced, without forcing conversion of the lazy ones. */
export function withChanges(node: Subcommand, changes: Partial<Subcommand>): Subcommand {
  const result = Object.create(null) as Record<string, unknown>;
  for (const key of Object.keys(node)) {
    Object.defineProperty(result, key, Object.getOwnPropertyDescriptor(node, key) as PropertyDescriptor);
  }
  for (const [key, value] of Object.entries(changes)) {
    Object.defineProperty(result, key, { value, enumerable: true, configurable: true, writable: true });
  }
  const derived = result as unknown as Subcommand;
  origins.set(derived, originOf(node));
  return derived;
}
