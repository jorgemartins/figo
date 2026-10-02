/**
 * Gathers every candidate for the current parse, in the order that breaks priority ties
 * (engine doc §6.1–6.3): subcommands, argument values, additional suggestions, options.
 */
import type { SuggestionType } from "../contract";
import { type ParseResult, SuggestionFlag } from "../parser/parse";
import type { Annotation, ParsedArg } from "../parser/state";
import { repeatLimit, timesPassed } from "../parser/state";
import type { Option, Subcommand } from "../specs/types";
import { hasControlCharacters, isObject, makeArray } from "../utils";
import type { Item } from "./types";

export interface GeneratorResults {
  generator: Fig.Generator;
  loading: boolean;
  /** Not started yet: its results, if any, are from an earlier run. */
  pending?: boolean;
  result: Item[];
}

const SUGGESTION_TYPES = new Set<string>([
  "folder",
  "file",
  "arg",
  "subcommand",
  "option",
  "special",
  "mixin",
  "shortcut",
  "history",
  "auto-execute",
]);

/** Names an entry can be typed as: a name with control characters never is (it would be keystrokes). */
function names(name: unknown): string[] {
  return makeArray(name as string | string[]).filter(
    (n): n is string => typeof n === "string" && n !== "" && !hasControlCharacters(n),
  );
}

/** Converts a spec or generator suggestion; null when it has no usable name. */
export function itemFromSuggestion(
  suggestion: string | Fig.Suggestion,
  defaults: { type?: SuggestionType; isDangerous?: boolean; generator?: Fig.Generator },
): Item | null {
  if (typeof suggestion === "string") {
    return names(suggestion).length === 0
      ? null
      : { type: defaults.type, names: [suggestion], isDangerous: defaults.isDangerous };
  }
  if (!isObject(suggestion)) {
    return null;
  }
  const itemNames = names(suggestion.name);
  if (itemNames.length === 0) {
    return null;
  }
  const type =
    typeof suggestion.type === "string" && SUGGESTION_TYPES.has(suggestion.type)
      ? (suggestion.type as SuggestionType)
      : defaults.type;
  const context = (suggestion as { context?: { templateType?: string } }).context;
  return {
    type,
    names: itemNames,
    displayName: typeof suggestion.displayName === "string" ? suggestion.displayName : undefined,
    description: typeof suggestion.description === "string" ? suggestion.description : undefined,
    icon: typeof suggestion.icon === "string" ? suggestion.icon : undefined,
    insertValue: typeof suggestion.insertValue === "string" ? suggestion.insertValue : undefined,
    priority: typeof suggestion.priority === "number" ? suggestion.priority : undefined,
    hidden: suggestion.hidden === true,
    isDangerous: typeof suggestion.isDangerous === "boolean" ? suggestion.isDangerous : defaults.isDangerous,
    generator: defaults.generator,
    templateType: isObject(context) && typeof context.templateType === "string" ? context.templateType : undefined,
  };
}

/**
 * Types a generator may give its entries. Generator output is data (script output, a project's
 * package.json), so it cannot make an entry run the line (`auto-execute`), delete extra text
 * (`shortcut`, `history`) or pass for a spec's subcommand or option. `special` is what Figo's own
 * help template produces; it has no power of its own.
 */
const GENERATED_TYPES = new Set<string>(["arg", "file", "folder", "special"]);

/** Generators may draw their own emoji or text, and `fig:` icons, but load nothing from elsewhere. */
function generatedIcon(icon: string | undefined): string | undefined {
  if (icon === undefined) {
    return undefined;
  }
  try {
    return new URL(icon).protocol === "fig:" ? icon : undefined;
  } catch {
    return icon;
  }
}

/**
 * What a generator's insert value may not contain, since it is typed as it is (`-- path`,
 * `name --flag`): anything that ends the command or starts another (`;`, `&`, `|`), redirects
 * (`<`, `>`), substitutes a command (backticks, `$(…)`, fish's bare `(…)`), expands into one
 * (any `$`: zsh's `${(e)…}` evaluates its value; `!` pastes a past command, `;` and all, back in)
 * or runs code from a glob (zsh's `*(e:…:)`). Such a value is ignored: the entry is typed as its
 * escaped name instead. Control characters are refused the same way.
 */
const UNSAFE_INSERT_VALUE = /[;&|<>`$()!]/;

/**
 * The row of an entry typed as its name: a generator's label may not hide that name. A label that
 * starts with it (`repo - 1a2b3c`) is kept; any other follows it (`web (Spring Web)`), so the row
 * still begins with what is typed. A label that merely contains the name could hide it in a word
 * (`rm` in `harmless form`).
 */
function generatedLabel(names: readonly string[], displayName: string | undefined): string | undefined {
  if (displayName === undefined) {
    return undefined;
  }
  const [only] = names;
  if (names.length === 1 && only !== undefined && displayName.startsWith(only)) {
    return displayName;
  }
  return `${names.join(", ")} (${displayName})`;
}

/**
 * Converts what a generator produced, without the powers only a spec may give an entry: its type
 * is argument-like, its insert value is plain text (no control characters, nothing that runs or
 * chains commands, no `{cursor}`, see `insert.ts`), its row shows what accepting it types, and it
 * is at least as dangerous as the argument it completes.
 */
export function itemFromGenerated(
  suggestion: Fig.Suggestion,
  defaults: { generator: Fig.Generator; isDangerous: boolean },
): Item | null {
  const item = itemFromSuggestion(suggestion, { type: "arg", generator: defaults.generator });
  if (item === null) {
    return null;
  }
  const type = item.type !== undefined && GENERATED_TYPES.has(item.type) ? item.type : "arg";
  let { insertValue } = item;
  if (
    insertValue !== undefined &&
    (insertValue === "" || hasControlCharacters(insertValue) || UNSAFE_INSERT_VALUE.test(insertValue))
  ) {
    insertValue = undefined;
  }
  // Files and folders are always typed as their escaped name; anything else types its insert value.
  const typesInsertValue = insertValue !== undefined && type !== "file" && type !== "folder";
  let displayName: string | undefined;
  if (typesInsertValue) {
    displayName = item.displayName === undefined && item.names.includes(insertValue ?? "") ? undefined : insertValue;
  } else {
    displayName = generatedLabel(item.names, item.displayName);
  }
  return {
    ...item,
    type,
    insertValue,
    displayName,
    icon: generatedIcon(item.icon),
    isDangerous: item.isDangerous === true || defaults.isDangerous || undefined,
  };
}

/** A trailing space after inserting: needed when an argument or a subcommand must follow. */
function shouldAddSpace(item: Subcommand | Option): boolean {
  const first = item.args[0];
  if (first && !first.isOptional) {
    return true;
  }
  if ("requiresSubcommand" in item && typeof item.requiresSubcommand === "boolean") {
    return item.requiresSubcommand;
  }
  return "subcommands" in item && item.subcommands.size > 0;
}

function separatorToAdd(option: Option, node: Subcommand, directives: ParseResult["directives"]): string | undefined {
  if (option.args[0]?.isOptional) {
    return undefined;
  }
  if (option.requiresSeparator) {
    if (typeof option.requiresSeparator === "string") {
      return option.requiresSeparator;
    }
    return makeArray(directives.optionArgSeparators ?? node.parserDirectives?.optionArgSeparators ?? "=")[0] ?? "=";
  }
  return option.requiresEquals ? "=" : undefined;
}

function specItem(spec: Subcommand | Option, type: SuggestionType): Item {
  return {
    type,
    names: spec.name,
    displayName: spec.displayName,
    description: spec.description,
    icon: spec.icon,
    insertValue: spec.insertValue,
    priority: spec.priority,
    hidden: spec.hidden === true,
    isDangerous: spec.isDangerous,
    args: spec.args,
    shouldAddSpace: shouldAddSpace(spec),
  };
}

const byFirstName = (a: Item, b: Item) => (a.names[0] ?? "").localeCompare(b.names[0] ?? "");

interface StaticItems {
  subcommands: Item[];
  additional: Item[];
  options: Item[];
}

let lastStatic: { key: unknown[]; items: StaticItems } | null = null;

function staticItems(result: ParseResult): StaticItems {
  const key = [result.node, result.passedOptions, result.persistent, result.directives];
  if (lastStatic && lastStatic.key.every((part, i) => part === key[i])) {
    return lastStatic.items;
  }
  const { node, passedOptions } = result;
  const subcommands = [...new Set(node.subcommands.values())]
    .filter((subcommand) => subcommand.name.length > 0)
    .map((subcommand) => specItem(subcommand, "subcommand"))
    .sort(byFirstName);

  const additional = makeArray(node.additionalSuggestions)
    .map((suggestion) => itemFromSuggestion(suggestion, { isDangerous: node.isDangerous }))
    .filter((item): item is Item => item !== null)
    .map((item) => (item.type || item.icon ? item : { ...item, icon: "fig://template?color=628dad&badge=➡️" }))
    .sort(byFirstName);

  const excluded = new Set<string>();
  const dependencies = new Set<string>();
  for (const option of passedOptions) {
    option.exclusiveOn?.forEach((name) => excluded.add(name));
    option.dependsOn?.forEach((name) => dependencies.add(name));
  }
  for (const option of passedOptions) {
    option.name.forEach((name) => dependencies.delete(name));
  }
  const allOptions = new Set([
    ...node.options.values(),
    ...node.persistentOptions.values(),
    ...result.persistent.values(),
  ]);
  const options = [...allOptions]
    .filter((option) => option.name.length > 0 && option.name.every((name) => !excluded.has(name)))
    .filter((option) => timesPassed(option, passedOptions) < repeatLimit(option))
    .map((option) => ({
      ...specItem(option, "option"),
      priority: option.name.some((name) => dependencies.has(name)) ? 75 : option.priority,
      separatorToAdd: separatorToAdd(option, node, result.directives),
    }))
    .sort(byFirstName);

  const items = { subcommands, additional, options };
  lastStatic = { key, items };
  return items;
}

function argItems(arg: ParsedArg | null): Item[] {
  if (!arg) {
    return [];
  }
  return makeArray(arg.suggestions)
    .map((suggestion) => itemFromSuggestion(suggestion, { type: "arg", isDangerous: arg.isDangerous }))
    .filter((item): item is Item => item !== null);
}

function shortOptionName(item: Item): string | undefined {
  return item.names.find((name) => name.startsWith("-") && !name.startsWith("--") && name.length === 2);
}

/** While typing `-la`: offer to extend the chain, and match the chain itself exactly. */
function rewriteOptionChain(items: Item[], options: Item[], flags: number, chain: string): Item[] {
  const lastFlag = `-${chain.charAt(chain.length - 1)}`;
  const kept = items.filter((item) => item.type === "option" || item.type === "arg");
  if (!(flags & SuggestionFlag.Options)) {
    // The last flag takes a mandatory argument, so options are off; still show the flag itself.
    const own = options.find((option) => shortOptionName(option) === lastFlag);
    if (own) {
      kept.push(own);
    }
  }
  return kept.map((item) => {
    if (item.type === "arg") {
      return { ...item, queryTerm: () => "" };
    }
    const short = shortOptionName(item);
    if (short === undefined) {
      return item;
    }
    if (short === lastFlag) {
      return { ...item, names: item.names.map((name) => (name === short ? chain : name)) };
    }
    const extended = `${chain}${short.charAt(1)}`;
    return { ...item, names: [extended], insertValue: extended };
  });
}

export function collectSuggestions(result: ParseResult, generators: readonly GeneratorResults[]): Item[] {
  const { subcommands, additional, options } = staticItems(result);
  let items: Item[] = [];
  if (result.flags & SuggestionFlag.Subcommands) {
    items.push(...subcommands);
  }
  if (result.flags & SuggestionFlag.Args) {
    items.push(...argItems(result.currentArg));
    for (const state of generators) {
      // Stale results of path-like generators would be filtered against the wrong directory.
      if ((!state.loading && !state.pending) || !state.generator.getQueryTerm) {
        items.push(...state.result);
      }
    }
  }
  items.push(...additional);
  if (result.flags & SuggestionFlag.Options) {
    items.push(...options);
  }
  const last: Annotation | undefined = result.annotations[result.annotations.length - 1];
  if (last?.type === "composite" && last.subtokens[last.subtokens.length - 1]?.type === "option") {
    items = rewriteOptionChain(items, options, result.flags, last.text);
  }
  return items;
}
