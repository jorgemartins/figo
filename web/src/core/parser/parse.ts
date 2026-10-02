/**
 * Walks a command's tokens through its spec (engine doc §4.7) and derives what the token under the
 * cursor can be. Figo deviations: a command without a usable spec, and a token the parser cannot
 * place, fall back to file and folder completion for the current token instead of failing.
 */
import { wordsOfSimpleCommand } from "../shell/tokenize";
import { convertSubcommand, withChanges } from "../specs/convert";
import { DisabledSpecError } from "../specs/load";
import { specLocationFor } from "../specs/location";
import {
  type Arg,
  type ExecuteCommand,
  type LoadSpec,
  type Option,
  type ParserDirectives,
  type SpecLocation,
  type Subcommand,
  serializeLocation,
} from "../specs/types";
import { isObject } from "../utils";
import {
  type Annotation,
  type ParsedArg,
  type ParserState,
  argStateInUse,
  canConsumeOptions,
  canConsumeSubcommands,
  createArgState,
  currentArg,
  initialState,
  lastKind,
  preferOptionArg,
  updateState,
} from "./state";

export const SuggestionFlag = { Subcommands: 1, Options: 2, Args: 4, Any: 7 } as const;

export interface ParseResult {
  node: Subcommand;
  directives: ParserDirectives;
  /** Persistent options inherited from ancestors of `node`. */
  persistent: ReadonlyMap<string, Option>;
  currentArg: ParsedArg | null;
  passedOptions: Option[];
  /** The text of the token being completed (an option chain's attached value, if any). */
  searchTerm: string;
  /** Where the command whose spec is in use starts (`sudo git …` → 1). */
  commandIndex: number;
  flags: number;
  annotations: Annotation[];
  /** The token texts after alias substitution, including the one being completed. */
  tokens: string[];
  /** True when the result is Figo's file-completion fallback rather than a spec's answer. */
  fallback: boolean;
}

export interface ParseContext {
  cwd: string;
  loadSpec: (location: SpecLocation) => Promise<Subcommand>;
  executeCommand: ExecuteCommand;
  /** The spec used while the first word is being typed. */
  firstTokenSpec: Subcommand;
  cache: ParseCache | null;
}

interface Walk {
  state: ParserState;
  /** The tokens before the one being completed, after alias substitution. */
  tokens: string[];
  /** A token before the one being completed could not be placed: complete files instead. */
  unplaced: boolean;
  usedGenerateSpec: boolean;
}

const MAX_CACHED_WALKS = 100;

/**
 * Remembers the parser state for a command prefix (every token but the last). Besides saving
 * work, this keeps argument objects identical while the user types within one token, which is
 * what tells the generator layer that the argument has not changed.
 */
export class ParseCache {
  private readonly walks = new Map<string, Walk>();

  get(key: string): Walk | undefined {
    const walk = this.walks.get(key);
    if (walk !== undefined) {
      this.walks.delete(key);
      this.walks.set(key, walk);
    }
    return walk;
  }

  set(key: string, walk: Walk): void {
    this.walks.set(key, walk);
    if (this.walks.size > MAX_CACHED_WALKS) {
      const oldest = this.walks.keys().next().value;
      if (oldest !== undefined) {
        this.walks.delete(oldest);
      }
    }
  }

  /** Drops prefixes whose spec was generated at runtime (`git help -a`, package.json, …). */
  clearGenerated(): void {
    for (const [key, walk] of this.walks) {
      if (walk.usedGenerateSpec) {
        this.walks.delete(key);
      }
    }
  }

  clear(): void {
    this.walks.clear();
  }
}

const FALLBACK_LOCATION: SpecLocation = { type: "global", name: "" };
const FALLBACK_SPEC = convertSubcommand({
  name: "",
  args: { name: "", isVariadic: true, template: ["filepaths", "folders"] },
});

/** Arguments handed out per cached walk, so a fresh copy made for the final token keeps its identity. */
const stableArgs = new WeakMap<ParserState, Map<Arg, ParsedArg>>();

function stabilize(owner: ParserState, arg: ParsedArg | null): ParsedArg | null {
  if (arg === null) {
    return null;
  }
  let memo = stableArgs.get(owner);
  if (memo === undefined) {
    memo = new Map();
    stableArgs.set(owner, memo);
  }
  const known = memo.get(arg.source);
  if (known !== undefined) {
    return known;
  }
  memo.set(arg.source, arg);
  return arg;
}

function resultFromState(state: ParserState, tokens: string[], owner: ParserState, fallback: boolean): ParseResult {
  const last = state.annotations[state.annotations.length - 1];
  let argState = argStateInUse(state);
  let searchTerm = last?.text ?? "";
  let onlyArgs = state.endOfOptions;
  if (last?.type === "composite") {
    argState = state.optionArgs;
    const lastSubtoken = last.subtokens[last.subtokens.length - 1];
    if (lastSubtoken?.type === "option_arg") {
      searchTerm = lastSubtoken.text;
      onlyArgs = true;
    }
  }
  let flags: number = SuggestionFlag.Args;
  if (!onlyArgs) {
    if (canConsumeSubcommands(state)) {
      flags |= SuggestionFlag.Subcommands;
    }
    if (canConsumeOptions(state)) {
      flags |= SuggestionFlag.Options;
    }
  }
  return {
    node: state.node,
    directives: state.directives,
    persistent: state.persistent,
    currentArg: stabilize(owner, currentArg(argState)),
    passedOptions: state.passedOptions,
    searchTerm,
    commandIndex: state.commandIndex,
    flags,
    annotations: state.annotations,
    tokens,
    fallback,
  };
}

function fallbackResult(walk: Walk, finalToken: string): ParseResult {
  const files = stabilize(walk.state, createArgState(FALLBACK_SPEC.args).args?.[0] ?? null);
  return {
    node: FALLBACK_SPEC,
    directives: {},
    persistent: new Map(),
    currentArg: files,
    passedOptions: [],
    searchTerm: finalToken,
    commandIndex: walk.state.commandIndex,
    flags: SuggestionFlag.Args,
    annotations: [...walk.state.annotations, { type: "subcommand_arg", text: finalToken, arg: files ?? undefined }],
    tokens: [...walk.tokens, finalToken],
    fallback: true,
  };
}

const REDIRECT_ARG = createArgState(FALLBACK_SPEC.args).args?.[0] ?? null;

/** The target of a redirection (`cat x > fi`) is always a file name. */
export function redirectTargetResult(tokens: readonly string[]): ParseResult {
  const searchTerm = tokens[tokens.length - 1] ?? "";
  return {
    node: FALLBACK_SPEC,
    directives: {},
    persistent: new Map(),
    currentArg: REDIRECT_ARG,
    passedOptions: [],
    searchTerm,
    commandIndex: 0,
    flags: SuggestionFlag.Args,
    annotations: [{ type: "subcommand_arg", text: searchTerm, arg: REDIRECT_ARG ?? undefined }],
    tokens: [...tokens],
    fallback: true,
  };
}

/** Parses a command line's tokens; the last one is the token being completed. */
export async function parseArguments(tokens: readonly string[], context: ParseContext): Promise<ParseResult> {
  const [first] = tokens;
  if (first === undefined) {
    throw new Error("Nothing to parse");
  }
  if (tokens.length === 1) {
    return parseFirstToken(first, context);
  }
  const walk = await walkPrefix([...tokens], context, undefined, 0);
  const finalToken = tokens[tokens.length - 1] ?? "";
  if (walk.unplaced) {
    return fallbackResult(walk, finalToken);
  }
  let state: ParserState;
  try {
    state = updateState(walk.state, finalToken, true);
  } catch {
    state = { ...walk.state, annotations: [...walk.state.annotations, { type: "none", text: finalToken }] };
  }
  return resultFromState(state, [...walk.tokens, finalToken], walk.state, walk.state.node === FALLBACK_SPEC);
}

async function parseFirstToken(token: string, context: ParseContext): Promise<ParseResult> {
  if (!token.includes("/")) {
    const key = `first\0${context.firstTokenSpec.args.length}`;
    let walk = context.cache?.get(key);
    if (walk === undefined) {
      const state = initialState(context.firstTokenSpec, token, { type: "global", name: "firstTokenSpec" });
      walk = { state, tokens: [], unplaced: false, usedGenerateSpec: false };
      context.cache?.set(key, walk);
    }
    const state = {
      ...walk.state,
      annotations: [{ ...walk.state.annotations[0], type: "subcommand" as const, text: token }],
    };
    return resultFromState(state, [token], walk.state, false);
  }
  // A path is being typed as the command: complete files (`./scr` → `./scripts/`).
  const location: SpecLocation = { type: "global", name: token === "bin/console" ? "php/bin-console" : "dotslash" };
  const key = `first\0${serializeLocation(location)}\0${context.cwd}`;
  let walk = context.cache?.get(key);
  if (walk === undefined) {
    let spec = FALLBACK_SPEC;
    try {
      spec = await context.loadSpec(location);
    } catch (error) {
      if (error instanceof DisabledSpecError) {
        throw error;
      }
    }
    walk = { state: initialState(spec, token, location), tokens: [], unplaced: false, usedGenerateSpec: false };
    context.cache?.set(key, walk);
  }
  const state = {
    ...walk.state,
    annotations: [{ type: "subcommand" as const, text: token, spec: walk.state.node, location }],
  };
  return resultFromState(state, [token], walk.state, walk.state.node === FALLBACK_SPEC);
}

function cacheKey(tokens: readonly string[], start: number, location: SpecLocation, cwd: string): string {
  return [tokens.slice(start, -1).join("\0"), serializeLocation(location), cwd].join("\u0001");
}

async function loadFirstAvailable(
  locations: readonly SpecLocation[],
  context: ParseContext,
): Promise<{ spec: Subcommand; location: SpecLocation } | null> {
  for (const location of locations) {
    try {
      return { spec: await context.loadSpec(location), location };
    } catch (error) {
      if (error instanceof DisabledSpecError) {
        throw error;
      }
    }
  }
  return null;
}

async function applyGenerateSpec(state: ParserState, tokens: string[], context: ParseContext): Promise<ParserState> {
  const { generateSpec } = state.node;
  if (!generateSpec) {
    return state;
  }
  // Generated once per node and walk: the merged node no longer carries the function.
  const withoutGenerator = withChanges(state.node, { generateSpec: undefined });
  try {
    const result = await generateSpec(tokens, context.executeCommand);
    if (!isObject(result)) {
      return { ...state, node: withoutGenerator };
    }
    const generated = convertSubcommand(result as unknown as Fig.Subcommand);
    const keepArgs = state.node.args.length > 0;
    const node = withChanges(withoutGenerator, {
      subcommands: new Map([...state.node.subcommands, ...generated.subcommands]),
      options: new Map([...state.node.options, ...generated.options]),
      persistentOptions: new Map([...state.node.persistentOptions, ...generated.persistentOptions]),
      args: keepArgs ? state.node.args : generated.args,
    });
    return { ...state, node, subcommandArgs: keepArgs ? state.subcommandArgs : createArgState(generated.args) };
  } catch {
    return { ...state, node: withoutGenerator };
  }
}

async function resolveLoadSpec(
  loadSpec: LoadSpec | undefined,
  token: string | undefined,
  context: ParseContext,
): Promise<SpecLocation[] | Subcommand | undefined> {
  if (typeof loadSpec !== "function") {
    return loadSpec;
  }
  if (token === undefined) {
    return undefined;
  }
  try {
    return await loadSpec(token, context.executeCommand);
  } catch {
    return undefined;
  }
}

function switchToSpec(state: ParserState, spec: Subcommand): ParserState {
  return {
    ...state,
    node: spec,
    directives: { ...state.directives, ...spec.parserDirectives },
    optionArgs: { args: null, index: 0 },
    passedOptions: [],
    subcommandArgs: createArgState(spec.args),
    enteredSubcommandArgs: false,
  };
}

async function walkPrefix(
  allTokens: string[],
  context: ParseContext,
  locations: SpecLocation[] | undefined,
  start: number,
): Promise<Walk> {
  let tokens = allTokens;
  const firstWord = tokens[start] ?? "";
  const candidates = locations ?? [specLocationFor(firstWord, context.cwd)];
  for (const location of candidates) {
    const cached = context.cache?.get(cacheKey(tokens, start, location, context.cwd));
    if (cached !== undefined) {
      return cached;
    }
  }

  const loaded = await loadFirstAvailable(candidates, context);
  const location = loaded?.location ?? candidates[0] ?? FALLBACK_LOCATION;
  // Keyed by the tokens as given, before any alias substitution, since that is what the next lookup has.
  const key = cacheKey(allTokens, start, location, context.cwd);
  let state = initialState(loaded?.spec ?? FALLBACK_SPEC, firstWord, location);
  let usedGenerateSpec = false;
  let unplaced = false;
  const substituted = new Set<string>();

  const remember = (walk: Walk): Walk => {
    context.cache?.set(key, walk);
    return walk;
  };
  const delegate = async (to: SpecLocation[], index: number): Promise<Walk> => {
    const inner = await walkPrefix(tokens, context, to, start + index);
    return remember({
      ...inner,
      usedGenerateSpec: inner.usedGenerateSpec || usedGenerateSpec,
      state: { ...inner.state, commandIndex: inner.state.commandIndex + index },
    });
  };

  const rootLoad = await resolveLoadSpec(state.node.loadSpec, undefined, context);
  if (Array.isArray(rootLoad) && rootLoad.length > 0) {
    return delegate(rootLoad, 0);
  }
  if (rootLoad !== undefined && !Array.isArray(rootLoad)) {
    state = switchToSpec(state, rootLoad);
  }

  for (let i = 1; start + i < tokens.length; i += 1) {
    if (state.node.generateSpec) {
      state = await applyGenerateSpec(state, tokens.slice(start), context);
      usedGenerateSpec = true;
    }
    if (start + i === tokens.length - 1) {
      break;
    }
    const token = tokens[start + i] ?? "";
    const pendingArg = currentArg(argStateInUse(state));
    const pendingArgKind = preferOptionArg(state) ? "option_arg" : "subcommand_arg";
    const before = state;
    try {
      state = updateState(state, token);
    } catch {
      state = { ...state, annotations: [...state.annotations, { type: "none", text: token }] };
      unplaced = true;
      break;
    }
    const kind = lastKind(state);

    const alias = pendingArg?.parserDirectives?.alias;
    if (kind === pendingArgKind && alias !== undefined && !substituted.has(token)) {
      let words: string[] | null = null;
      try {
        const value = typeof alias === "string" ? alias : await alias(token, context.executeCommand);
        words = wordsOfSimpleCommand(value)?.map((word) => word.text) ?? null;
      } catch {
        words = null;
      }
      if (words === null || words.length === 0) {
        // Upstream fails the whole parse; an unresolvable alias degrades to file completion.
        unplaced = true;
        break;
      }
      tokens = [...tokens.slice(0, start + i), ...words, ...tokens.slice(start + i + 1)];
      substituted.add(token);
      state = before;
      i -= 1;
      continue;
    }

    let loadSpec: LoadSpec | undefined = kind === "subcommand" ? state.node.loadSpec : undefined;
    if (kind === pendingArgKind && pendingArg) {
      if (pendingArg.loadSpec) {
        loadSpec = pendingArg.loadSpec;
      } else if (pendingArg.isCommand || pendingArg.isScript) {
        loadSpec = [specLocationFor(token, context.cwd, Boolean(pendingArg.isScript))];
      } else if (pendingArg.isModule) {
        loadSpec = [{ type: "global", name: `${pendingArg.isModule}${token}` }];
      }
    }
    const resolved = await resolveLoadSpec(loadSpec, token, context);
    if (Array.isArray(resolved) && resolved.length > 0) {
      return delegate(resolved, i);
    }
    if (resolved !== undefined && !Array.isArray(resolved)) {
      state = switchToSpec(state, resolved);
    }
    substituted.clear();
  }
  return remember({ state, tokens: tokens.slice(0, -1), unplaced, usedGenerateSpec });
}
