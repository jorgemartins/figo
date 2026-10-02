/**
 * The argument parser's state machine: how one token moves the state through a spec. Token
 * precedence is subcommand, then option syntax, then the pending option's argument, then a
 * positional argument (engine doc §4).
 */
import { pathsGenerator } from "../generators/paths";
import type { Arg, Option, ParserDirectives, SpecLocation, Subcommand } from "../specs/types";
import { makeArray } from "../utils";

/** An argument as the parser hands it out: templates replaced by Figo's own generators. */
export interface ParsedArg extends Arg {
  /** The spec's argument this was prepared from (stable for as long as the spec is cached). */
  source: Arg;
}

export interface ArgState {
  args: ParsedArg[] | null;
  index: number;
  variadicCount?: number;
}

export type TokenKind = "none" | "subcommand" | "option" | "option_arg" | "subcommand_arg";

export type BasicAnnotation =
  | { type: "subcommand"; text: string; spec?: Subcommand; location?: SpecLocation }
  | { type: "option"; text: string; tokenName?: string }
  | { type: "option_arg" | "subcommand_arg"; text: string; arg?: ParsedArg }
  | { type: "none"; text: string };

export type Annotation = BasicAnnotation | { type: "composite"; text: string; subtokens: BasicAnnotation[] };

export interface ParserState {
  /** The spec node being completed (`completionObj` upstream). */
  node: Subcommand;
  /** Parser directives in effect: a node without its own inherits its parent's. */
  directives: ParserDirectives;
  /** Persistent options of every ancestor, merged as the parser descends. */
  persistent: ReadonlyMap<string, Option>;
  optionArgs: ArgState;
  subcommandArgs: ArgState;
  annotations: Annotation[];
  passedOptions: Option[];
  commandIndex: number;
  enteredSubcommandArgs: boolean;
  endOfOptions: boolean;
}

export class UpdateStateError extends Error {}

const EMPTY_ARGS: ArgState = { args: null, index: 0 };

/** Replaces filepaths/folders templates with fresh generator objects, so nothing is shared. */
export function prepareArg(arg: Arg): ParsedArg {
  const generators: Fig.Generator[] = [];
  for (const generator of arg.generators) {
    const templates = makeArray(generator.template);
    if (templates.length === 0) {
      if (!generators.includes(generator)) {
        generators.push(generator);
      }
      continue;
    }
    if (templates.includes("filepaths") || templates.includes("folders")) {
      generators.push(
        pathsGenerator({
          foldersOnly: !templates.includes("filepaths"),
          filterTemplateSuggestions: generator.filterTemplateSuggestions,
        }),
      );
    }
    // Upstream drops other templates listed next to filepaths (["history", "filepaths"]); keep them.
    const others = templates.filter((template) => template !== "filepaths" && template !== "folders");
    if (others.length > 0) {
      generators.push({ ...generator, template: others });
    }
  }
  return { ...arg, generators, source: arg };
}

export function createArgState(args?: readonly Arg[]): ArgState {
  return args && args.length > 0 ? { args: args.map(prepareArg), index: 0 } : EMPTY_ARGS;
}

export function currentArg(state: ArgState): ParsedArg | null {
  return state.args?.[state.index] ?? null;
}

export function advanceArgState(state: ArgState): ArgState {
  const arg = currentArg(state);
  if (arg?.isVariadic) {
    return { ...state, variadicCount: (state.variadicCount ?? 0) + 1 };
  }
  if (arg && state.args && state.index < state.args.length - 1) {
    return { args: state.args, index: state.index + 1 };
  }
  return EMPTY_ARGS;
}

export function isMandatoryOrVariadic(arg: Arg | null): boolean {
  return arg !== null && (Boolean(arg.isVariadic) || !arg.isOptional);
}

export function canConsumeSubcommands(state: ParserState): boolean {
  return !isMandatoryOrVariadic(currentArg(state.optionArgs)) && !state.enteredSubcommandArgs;
}

export function canConsumeOptions(state: ParserState): boolean {
  if (state.enteredSubcommandArgs && state.directives.optionsMustPrecedeArguments === true) {
    return false;
  }
  if (state.endOfOptions) {
    return false;
  }
  const optionArg = currentArg(state.optionArgs);
  if (isMandatoryOrVariadic(optionArg)) {
    return Boolean(
      optionArg?.isVariadic && state.optionArgs.variadicCount && optionArg.optionsCanBreakVariadicArg !== false,
    );
  }
  const subcommandArg = currentArg(state.subcommandArgs);
  if (subcommandArg && state.subcommandArgs.variadicCount && subcommandArg.optionsCanBreakVariadicArg === false) {
    return false;
  }
  return true;
}

export function preferOptionArg(state: ParserState): boolean {
  return isMandatoryOrVariadic(currentArg(state.optionArgs)) || !currentArg(state.subcommandArgs);
}

export function argStateInUse(state: ParserState): ArgState {
  return preferOptionArg(state) ? state.optionArgs : state.subcommandArgs;
}

export function findOption(state: ParserState, name: string): Option {
  const option = state.node.options.get(name) ?? state.node.persistentOptions.get(name) ?? state.persistent.get(name);
  if (!option) {
    throw new UpdateStateError(`Unknown option ${name}`);
  }
  return option;
}

function optionsEqual(a: Option, b: Option): boolean {
  return a.name.some((name) => b.name.includes(name));
}

export function timesPassed(option: Option, passed: readonly Option[]): number {
  return passed.filter((other) => optionsEqual(option, other)).length;
}

/**
 * How often the suggestion list offers an option; unset means once. The parser accepts any number
 * of repeats, as upstream: specs often leave `isRepeatable` out (`docker run -e`, `curl -H`), and
 * refusing the second one threw the rest of the line off.
 */
export function repeatLimit(option: Option): number {
  const { isRepeatable } = option;
  if (isRepeatable === true) {
    return Number.POSITIVE_INFINITY;
  }
  return typeof isRepeatable === "number" && isRepeatable > 0 ? isRepeatable : 1;
}

function withAnnotation(state: ParserState, annotation: Annotation): Annotation[] {
  return [...state.annotations, annotation];
}

function forSubcommand(state: ParserState, token: string, isFinal: boolean): ParserState {
  if (state.enteredSubcommandArgs) {
    throw new UpdateStateError("Already entered subcommand arguments");
  }
  const child = state.node.subcommands.get(token);
  if (!child) {
    throw new UpdateStateError(`Unknown subcommand ${token}`);
  }
  const annotations = withAnnotation(state, { type: "subcommand", text: token });
  if (isFinal) {
    return { ...state, annotations };
  }
  const persistent = new Map(state.persistent);
  for (const [name, option] of state.node.persistentOptions) {
    persistent.set(name, option);
  }
  return {
    ...state,
    annotations,
    node: child,
    directives: child.parserDirectives ?? state.directives,
    persistent,
    passedOptions: [],
    optionArgs: EMPTY_ARGS,
    subcommandArgs: createArgState(child.args),
  };
}

function forOption(state: ParserState, token: string, isFinal: boolean): ParserState {
  const option = findOption(state, token);
  const annotations = withAnnotation(state, { type: "option", text: token });
  if (isFinal) {
    return { ...state, annotations };
  }
  return {
    ...state,
    annotations,
    passedOptions: [...state.passedOptions, option],
    optionArgs: createArgState(option.args),
  };
}

function forOptionArg(state: ParserState, token: string, isFinal: boolean): ParserState {
  const arg = currentArg(state.optionArgs);
  if (!arg) {
    throw new UpdateStateError("No option argument to consume");
  }
  const annotations = withAnnotation(state, { type: "option_arg", text: token, arg });
  if (isFinal) {
    return { ...state, annotations };
  }
  return { ...state, annotations, optionArgs: advanceArgState(state.optionArgs) };
}

function forSubcommandArg(state: ParserState, token: string, isFinal: boolean): ParserState {
  const arg = currentArg(state.subcommandArgs);
  if (!arg) {
    throw new UpdateStateError("No argument to consume");
  }
  const annotations = withAnnotation(state, { type: "subcommand_arg", text: token, arg });
  if (isFinal) {
    return { ...state, annotations };
  }
  return { ...state, annotations, subcommandArgs: advanceArgState(state.subcommandArgs), enteredSubcommandArgs: true };
}

function separatorsOf(directives: ParserDirectives): Set<string> {
  // Each character is a separator on its own; multi-character separators never match upstream either.
  return new Set(makeArray(directives.optionArgSeparators ?? "=").join(""));
}

function forOptionToken(state: ParserState, token: string, isFinal: boolean): ParserState {
  // A lone dash while typing is a query, not an option.
  if (isFinal && (token === "-" || token === "--")) {
    throw new UpdateStateError("Not consuming a lone dash as an option");
  }
  if (token === "-") {
    // An argument (standard input, the previous directory), unless the spec has a `-` option.
    return forOption(state, token, isFinal);
  }
  if (token === "--") {
    let ended: ParserState;
    try {
      // A spec's own `--` takes what follows as its argument (`npm run build -- …`).
      ended = forOption(state, token, isFinal);
    } catch {
      ended = { ...state, annotations: withAnnotation(state, { type: "option", text: token }), optionArgs: EMPTY_ARGS };
    }
    return { ...ended, endOfOptions: true };
  }

  const isLong =
    Boolean(state.directives.flagsArePosixNoncompliant) || token.startsWith("--") || !token.startsWith("-");
  if (isLong) {
    const separators = separatorsOf(state.directives);
    let at = -1;
    for (let i = 0; i < token.length && at === -1; i += 1) {
      if (separators.has(token.charAt(i))) {
        at = i;
      }
    }
    if (at !== -1) {
      const separator = token.charAt(at);
      const flag = token.slice(0, at);
      const value = token.slice(at + 1);
      // The option itself is consumed even for the final token, so its argument is what completes.
      const withOption = forOption(state, flag, false);
      if ((withOption.optionArgs.args?.length ?? 0) > 1) {
        throw new UpdateStateError("A separator only works for options taking one argument");
      }
      const result = forOptionArg(withOption, value, isFinal);
      return {
        ...result,
        annotations: withAnnotation(state, {
          type: "composite",
          text: token,
          subtokens: [
            { type: "option", text: `${flag}${separator}`, tokenName: flag },
            { type: "option_arg", text: value, arg: currentArg(withOption.optionArgs) ?? undefined },
          ],
        }),
      };
    }
    const result = forOption(state, token, isFinal);
    const option = findOption(state, token);
    // `--opt value` does not give `value` to an option that requires `--opt=value`.
    return option.requiresSeparator || option.requiresEquals ? { ...result, optionArgs: EMPTY_ARGS } : result;
  }

  // A POSIX chain such as `-abc` or `-ovalue`.
  let current = state;
  let value = "";
  let passedBeforeLast = state.passedOptions;
  const subtokens: BasicAnnotation[] = [];
  for (let i = 1; i < token.length; i += 1) {
    const flag = `-${token.charAt(i)}`;
    passedBeforeLast = current.passedOptions;
    try {
      current = forOption(current, flag, false);
    } catch (error) {
      if (i > 1) {
        value = token.slice(i);
        break;
      }
      throw error;
    }
    subtokens.push({ type: "option", text: i === 1 ? flag : token.charAt(i), tokenName: flag });
    if (isMandatoryOrVariadic(currentArg(current.optionArgs))) {
      value = token.slice(i + 1);
      break;
    }
  }
  if (value) {
    if ((current.optionArgs.args?.length ?? 0) > 1) {
      throw new UpdateStateError("Cannot attach an argument to an option taking several");
    }
    const arg = currentArg(current.optionArgs) ?? undefined;
    current = forOptionArg(current, value, isFinal);
    passedBeforeLast = current.passedOptions;
    subtokens.push({ type: "option_arg", text: value, arg });
  }
  return {
    ...current,
    annotations: withAnnotation(state, { type: "composite", text: token, subtokens }),
    // While typing `-la` the last flag stays suggestible.
    passedOptions: isFinal ? passedBeforeLast : current.passedOptions,
  };
}

/** Moves the state over one token; throws UpdateStateError when nothing can consume it. */
export function updateState(state: ParserState, token: string, isFinal = false): ParserState {
  if (canConsumeSubcommands(state)) {
    try {
      return forSubcommand(state, token, isFinal);
    } catch {
      // Not a subcommand; try the next kind.
    }
  }
  if (canConsumeOptions(state)) {
    try {
      return forOptionToken(state, token, isFinal);
    } catch {
      // Not an option.
    }
  }
  if (preferOptionArg(state)) {
    try {
      return forOptionArg(state, token, isFinal);
    } catch {
      // No pending option argument.
    }
  }
  return forSubcommandArg(state, token, isFinal);
}

export function initialState(node: Subcommand, text: string, location: SpecLocation): ParserState {
  return {
    node,
    directives: node.parserDirectives ?? {},
    persistent: new Map(),
    optionArgs: EMPTY_ARGS,
    subcommandArgs: createArgState(node.args),
    annotations: [{ type: "subcommand", text, spec: node, location }],
    passedOptions: [],
    commandIndex: 0,
    enteredSubcommandArgs: false,
    endOfOptions: false,
  };
}

/** The kind of the last thing consumed (the last subtoken of a composite). */
export function lastKind(state: ParserState): TokenKind {
  const last = state.annotations[state.annotations.length - 1];
  if (!last) {
    return "none";
  }
  if (last.type === "composite") {
    return last.subtokens[last.subtokens.length - 1]?.type ?? "none";
  }
  return last.type;
}
