/**
 * The completion core: follows the focused session's command line, parses it, runs generators,
 * builds the list, and owns visibility, selection, key actions and insertion.
 */
import type { NativeBridge, NativeEvents, SessionId, Settings, ShellContext } from "../../bridge/contract";
import type { ActionId, Core, CoreOptions, CoreState } from "../contract";
import { GeneratorCache } from "../generators/cache";
import type { GeneratorContext, GeneratorServices } from "../generators/context";
import { createExecuteCommand, refuseToExecute } from "../generators/exec";
import { historyItems } from "../history/history";
import { commonPrefixOutcome } from "../insertion/commonPrefix";
import { type InsertionContext, fullInsertionText, insertionBytes } from "../insertion/insert";
import { type ParseContext, ParseCache, type ParseResult, parseArguments, redirectTargetResult } from "../parser/parse";
import { SETTING, booleanSetting, numberSetting, stringListSetting } from "../settings";
import { type AliasMap, parseAliases } from "../shell/aliases";
import { type Token, splitCommands } from "../shell/tokenize";
import { originOf } from "../specs/convert";
import { firstTokenSpec } from "../specs/firstToken";
import { COMMON_SPECS, type SpecIndex, SpecLoader } from "../specs/load";
import type { ExecuteCommand } from "../specs/types";
import { RecencyIndex, memoryStorage } from "../suggestions/recency";
import type { Item, RankedItem } from "../suggestions/types";
import { GeneratorRuns } from "./generatorRuns";
import { type LineRead, classifyEdit, readLine } from "./line";
import { buildList } from "./list";
import { coreStateOf, interceptFor } from "./output";
import { navigateTo, reselect } from "./selection";
import { SessionHistory } from "./sessionHistory";
import { type Visibility, visibilityAfterParse } from "./visibility";

/** How the edit that started a parse changed the line; decides visibility when it lands. */
interface PendingEdit {
  backspacedIntoPreviousToken: boolean;
  /** Not typing: a paste, history recall, … */
  largeChange: boolean;
  /** A re-parse for new settings or shell context, not a keystroke. */
  contextOnly: boolean;
}

/** What a displayed list was computed against; insertion always uses the list's own context. */
interface ListContext {
  result: ParseResult;
  token: Token | null;
  buffer: string;
  fuzzy: boolean;
}

const LOADING_DELAY_MS = 200;
const SIZE_STEP = 1.1;
const ACTIONS = new Set<string>([
  "insertSelected",
  "insertCommonPrefix",
  "insertCommonPrefixOrNavigateDown",
  "insertCommonPrefixOrInsertSelected",
  "insertSelectedAndExecute",
  "execute",
  "hideAutocomplete",
  "showAutocomplete",
  "toggleAutocomplete",
  "navigateUp",
  "navigateDown",
  "toggleDescription",
  "toggleHistoryMode",
  "toggleFuzzySearch",
  "increaseSize",
  "decreaseSize",
]);

/** Actions on the list itself: nothing to act on while the loading indicator is shown instead. */
const LIST_ACTIONS = new Set<ActionId>([
  "insertSelected",
  "insertSelectedAndExecute",
  "insertCommonPrefix",
  "insertCommonPrefixOrNavigateDown",
  "insertCommonPrefixOrInsertSelected",
  "navigateUp",
  "navigateDown",
]);

function defaultImportSpec(name: string): Promise<unknown> {
  return import(/* @vite-ignore */ `figo://specs/${name}.js`);
}

async function defaultLoadIndex(): Promise<SpecIndex> {
  const response = await fetch("figo://specs/index.json");
  return (await response.json()) as SpecIndex;
}

export class CompletionCore implements Core {
  private readonly listeners = new Set<(state: CoreState) => void>();
  private readonly unsubscribers: Array<() => void> = [];
  private readonly loader: SpecLoader;
  private readonly parseCache = new ParseCache();
  private readonly generatorCache = new GeneratorCache();
  private readonly generators: GeneratorRuns;
  private readonly recency: RecencyIndex;
  private readonly history: SessionHistory;
  private readonly contexts = new Map<SessionId, ShellContext>();
  private aliasCache: { raw: string; shell: string; map: AliasMap } | null = null;
  private disposed = false;

  private settings: Settings = {};
  private sessionId: SessionId | null = null;
  private buffer = "";
  private cursor = 0;

  /** The command line under the cursor, as last read. */
  private line: LineRead | null = null;
  /** Identifies what `line` parses to, so unchanged commands are not parsed again. */
  private lineKey = "";
  private parse: ParseResult | null = null;
  private parseSequence = 0;
  private parsePending = false;
  private pendingEdit: PendingEdit | null = null;

  private visibility: Visibility = "hiddenUntilKeypress";
  /**
   * A show key started the argument's generators: show the popup once they finish (`tab`: the
   * onlyShowOnTab Tab, which completes a single entry instead).
   */
  private revealWhenLoaded: "show" | "tab" | null = null;
  private lastInserted: Item | null = null;
  private justInserted = false;

  private items: RankedItem[] = [];
  private listContext: ListContext | null = null;
  /** The list was built for a buffer holding more than one command (see `isCompoundLine`). */
  private compoundLine = false;
  private selectedIndex = 0;
  private hasChangedIndex = false;

  private historyMode = false;
  private userFuzzy = false;
  private fuzzy = false;
  private loading = false;
  private loadingTimer: ReturnType<typeof setTimeout> | null = null;
  private descriptionPopout = false;
  private scale = 1;
  private shakeCount = 0;

  private state: CoreState;
  private lastIntercept = "";
  private readonly idleWaiters: Array<() => void> = [];

  constructor(
    private readonly bridge: NativeBridge,
    options: CoreOptions = {},
  ) {
    this.recency = new RecencyIndex(options.storage ?? memoryStorage());
    this.loader = new SpecLoader({
      importSpec: options.importSpec ?? defaultImportSpec,
      loadIndex: options.loadIndex ?? defaultLoadIndex,
      executeCommand: () => this.executeCommand(undefined),
      disabledCommands: () => stringListSetting(this.settings, SETTING.disableForCommands),
      onLateLoad: () => this.onLateSpec(),
    });
    this.generators = new GeneratorRuns(
      () => this.services(),
      () => {
        this.updateLoading();
        this.recompute();
        this.revealIfLoaded();
      },
      () => this.generatorsMayRun(),
    );
    this.history = new SessionHistory({
      bridge,
      session: () => (this.sessionId === null ? null : { id: this.sessionId, context: this.shellContext }),
      settings: () => this.settings,
      aliases: () => this.aliases(),
      parse: (tokens) =>
        parseArguments(tokens, { ...this.parseContext(), executeCommand: refuseToExecute, cache: null }),
    });
    this.state = this.buildState();
    this.listen("session", (context) => this.onSession(context));
    this.listen("editBuffer", (event) => this.onEditBuffer(event));
    this.listen("preExec", (event) => this.onSessionEvent(event.sessionId, () => this.clearLine()));
    this.listen("postExec", (event) => this.onPostExec(event));
    this.listen("keybinding", (event) => this.onKeybinding(event));
    this.listen("settings", (event) => this.applySettings(event.settings));
    this.listen("windowHidden", () => this.reset());
    bridge.call("app.ready", {}).then(
      (info) => {
        if (!this.disposed) {
          this.applySettings(info.settings ?? {});
        }
      },
      () => {
        // Without app info the defaults apply.
      },
    );
    // Importing a large spec is the slowest step of a first completion; do the common ones early.
    setTimeout(() => void this.loader.preload(COMMON_SPECS, () => this.disposed), 0);
  }

  // ---- Core ---------------------------------------------------------------------------------

  getState(): CoreState {
    return this.state;
  }

  subscribe(listener: (state: CoreState) => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  dispatch(action: ActionId): void {
    if (this.disposed) {
      return;
    }
    const selected = this.items[this.selectedIndex];
    const onlyShowOnTab = booleanSetting(this.settings, SETTING.onlyShowOnTab);
    const shows = action === "showAutocomplete" || action === "toggleAutocomplete";
    if (action === "hideAutocomplete") {
      this.revealWhenLoaded = null;
    }
    if (shows && this.revealWhenLoaded !== null) {
      return; // already on its way
    }
    if (shows && this.visibility !== "visible" && this.generators.start()) {
      // The argument's generators waited for the popup; it appears once they are done, rather
      // than showing a partial list first.
      this.revealWhenLoaded = onlyShowOnTab && action === "showAutocomplete" ? "tab" : "show";
      this.updateLoading();
      this.publish();
      return;
    }
    if (action === "showAutocomplete" && onlyShowOnTab && this.visibility !== "visible") {
      this.revealForTab();
      return;
    }
    // Upstream ignores every key while the list is empty. Keys stop being taken while the loading
    // indicator hides the list; one already on its way must not act on the hidden list either.
    if (!selected || (this.state.loading && this.state.visible && LIST_ACTIONS.has(action))) {
      return;
    }
    switch (action) {
      case "insertSelected":
        this.insertItem(selected, false);
        break;
      case "insertSelectedAndExecute":
        this.insertItem(selected, true);
        break;
      case "insertCommonPrefix":
        if (!this.insertCommonPrefix()) {
          this.shake();
        }
        break;
      case "insertCommonPrefixOrNavigateDown":
        if (!this.insertCommonPrefix()) {
          this.navigate(1);
        }
        break;
      case "insertCommonPrefixOrInsertSelected":
        if (!this.insertCommonPrefix()) {
          this.insertItem(selected, false);
        }
        break;
      case "execute":
        if (this.sessionId !== null) {
          void this.bridge.call("shell.insert", { sessionId: this.sessionId, text: "\n" }).catch(() => undefined);
        }
        break;
      case "navigateUp":
        this.navigate(-1);
        break;
      case "navigateDown":
        this.navigate(1);
        break;
      case "hideAutocomplete":
        this.setVisibility("hiddenUntilShown");
        break;
      case "showAutocomplete":
        this.setVisibility("visible");
        break;
      case "toggleAutocomplete":
        this.setVisibility(this.visibility === "visible" ? "hiddenUntilShown" : "visible");
        break;
      case "toggleHistoryMode":
        this.setHistoryMode(!this.historyMode);
        break;
      case "toggleDescription":
        if (!booleanSetting(this.settings, SETTING.alwaysShowDescription)) {
          this.descriptionPopout = !this.descriptionPopout;
          this.publish();
        }
        break;
      case "toggleFuzzySearch":
        // Applies at once (upstream waited for the next keystroke) and lasts until the argument changes.
        this.userFuzzy = !this.userFuzzy;
        this.fuzzy = this.parse ? this.fuzzyFor(this.parse) : this.userFuzzy;
        this.recompute();
        break;
      case "increaseSize":
        this.scale *= SIZE_STEP;
        this.publish();
        break;
      case "decreaseSize":
        this.scale /= SIZE_STEP;
        this.publish();
        break;
    }
  }

  insert(index: number): void {
    const item = this.items[index];
    if (item !== undefined && !this.disposed) {
      this.insertItem(item, false);
    }
  }

  dispose(): void {
    this.disposed = true;
    this.unsubscribers.forEach((unsubscribe) => unsubscribe());
    this.unsubscribers.length = 0;
    this.listeners.clear();
    this.parseSequence += 1;
    this.generators.clear();
    this.clearLoadingTimer();
    this.resolveIdle();
  }

  /** Resolves once no parse or generator is pending (for tests; see `testing/whenIdle`). */
  whenIdle(): Promise<void> {
    if (this.isIdle()) {
      return Promise.resolve();
    }
    return new Promise((resolve) => this.idleWaiters.push(resolve));
  }

  // ---- Events -------------------------------------------------------------------------------

  private listen<Event extends keyof NativeEvents>(
    event: Event,
    handler: (payload: NativeEvents[Event]) => void,
  ): void {
    this.unsubscribers.push(
      this.bridge.on(event, (payload) => {
        if (!this.disposed) {
          handler(payload);
        }
      }),
    );
  }

  private onSessionEvent(sessionId: SessionId, handler: () => void): void {
    if (sessionId === this.sessionId) {
      handler();
    }
  }

  private onSession(context: ShellContext): void {
    const previous = this.contexts.get(context.sessionId);
    this.contexts.set(context.sessionId, context);
    if (context.sessionId !== this.sessionId) {
      return;
    }
    if (previous?.cwd !== context.cwd) {
      this.parseCache.clear();
    }
    // Directory, aliases and environment can all change the parse.
    this.lineKey = "";
    this.refresh(true);
  }

  private onEditBuffer(event: NativeEvents["editBuffer"]): void {
    if (event.sessionId !== this.sessionId) {
      this.sessionId = event.sessionId;
      this.reset();
    }
    if (event.buffer === null) {
      this.clearLine();
      return;
    }
    this.buffer = event.buffer;
    this.cursor = Math.max(0, Math.min(event.cursor, event.buffer.length));
    this.refresh();
  }

  private onPostExec(event: NativeEvents["postExec"]): void {
    this.history.add(event.command);
    // The command may have changed what generated specs describe (a new branch, a new dependency).
    this.parseCache.clearGenerated();
  }

  /** A spec that took too long has loaded: forget what was parsed without it, and parse again. */
  private onLateSpec(): void {
    if (this.disposed) {
      return;
    }
    this.parseCache.clear();
    if (this.line !== null) {
      this.lineKey = "";
      this.refresh(true);
    }
  }

  private onKeybinding(event: NativeEvents["keybinding"]): void {
    if (event.sessionId === this.sessionId && ACTIONS.has(event.action)) {
      this.dispatch(event.action as ActionId);
    }
  }

  private applySettings(settings: Settings): void {
    const fuzzyChanged = settings[SETTING.fuzzySearch] !== this.settings[SETTING.fuzzySearch];
    this.settings = { ...settings };
    if (fuzzyChanged) {
      this.userFuzzy = booleanSetting(settings, SETTING.fuzzySearch);
      this.fuzzy = this.parse ? this.fuzzyFor(this.parse) : this.userFuzzy;
    }
    // Settings can change how commands parse (disabled commands, first-word completion).
    this.loader.clearFailures();
    this.parseCache.clear();
    if (this.line !== null) {
      this.lineKey = "";
      this.refresh(true);
    } else {
      this.publish();
    }
  }

  // ---- Reading and parsing the line ---------------------------------------------------------

  private get shellContext(): ShellContext | null {
    return this.sessionId === null ? null : (this.contexts.get(this.sessionId) ?? null);
  }

  private aliases(): AliasMap {
    const context = this.shellContext;
    if (!context || !context.aliases) {
      return new Map();
    }
    if (this.aliasCache?.raw !== context.aliases || this.aliasCache.shell !== context.shell) {
      this.aliasCache = {
        raw: context.aliases,
        shell: context.shell,
        map: parseAliases(context.aliases, context.shell),
      };
    }
    return this.aliasCache.map;
  }

  private executeCommand(cwd: string | undefined, timeoutMs = 5_000): ExecuteCommand {
    const sessionId = this.sessionId;
    if (sessionId === null) {
      return () => Promise.reject(new Error("No terminal session"));
    }
    return createExecuteCommand(this.bridge, sessionId, { cwd, timeoutMs });
  }

  private parseContext(): ParseContext {
    return {
      cwd: this.shellContext?.cwd ?? "",
      loadSpec: (location) => this.loader.load(location),
      executeCommand: this.executeCommand(undefined),
      firstTokenSpec: firstTokenSpec(booleanSetting(this.settings, SETTING.firstTokenCompletion)),
      cache: this.parseCache,
    };
  }

  /**
   * Re-reads the command under the cursor and parses it when it changed. `contextOnly` marks a
   * re-parse for new settings or shell context rather than a keystroke.
   */
  private refresh(contextOnly = false): void {
    const line = booleanSetting(this.settings, SETTING.disable)
      ? null
      : readLine(this.buffer, this.cursor, this.aliases(), this.shellContext?.shell ?? "");
    if (line === null) {
      this.reset();
      return;
    }
    const previous = this.line;
    this.line = line;
    const texts = line.command.tokens.map((token) => token.text);
    const key = JSON.stringify([texts, line.command.redirectTarget, this.shellContext?.cwd ?? "", this.sessionId]);
    if (key === this.lineKey) {
      // Same command, so the list still applies; keep its buffer current for insertion.
      if (this.listContext !== null) {
        this.listContext = { ...this.listContext, buffer: this.buffer, token: line.command.tokens.at(-1) ?? null };
      }
      if (this.isCompoundLine() !== this.compoundLine) {
        this.recompute(); // text elsewhere on the line decides whether a row may run it
      }
      return;
    }
    this.lineKey = key;

    const kind = classifyEdit(previous, line);
    let edit: PendingEdit = {
      backspacedIntoPreviousToken: kind.backspacedIntoPreviousToken && !contextOnly,
      largeChange: kind.largeChange && !contextOnly,
      contextOnly,
    };
    if (contextOnly && this.parsePending && this.pendingEdit !== null && !this.pendingEdit.contextOnly) {
      // A keystroke's parse is being superseded: its visibility rules still apply.
      edit = this.pendingEdit;
    }
    const sequence = ++this.parseSequence;
    if (line.command.redirectTarget) {
      this.parsePending = false;
      this.applyParse(redirectTargetResult(texts), edit);
      return;
    }
    this.parsePending = true;
    this.pendingEdit = edit;
    this.updateLoading();
    parseArguments(texts, this.parseContext()).then(
      (result) => this.onParsed(sequence, () => this.applyParse(result, edit)),
      () => this.onParsed(sequence, () => this.reset()),
    );
  }

  private onParsed(sequence: number, then: () => void): void {
    if (sequence !== this.parseSequence || this.disposed) {
      return; // a newer edit superseded this parse
    }
    this.parsePending = false;
    this.pendingEdit = null;
    then();
  }

  private fuzzyFor(result: ParseResult): boolean {
    // An argument's filterStrategy wins even for the subcommands listed next to it, as upstream.
    const strategy = result.currentArg ? result.currentArg.filterStrategy : result.node.filterStrategy;
    if (strategy === "prefix") {
      return false;
    }
    return strategy === "fuzzy" ? true : this.userFuzzy;
  }

  private applyParse(result: ParseResult, edit: PendingEdit): void {
    const previous = this.parse;
    // "New argument" is about the spec's argument, as upstream's deep comparison; the identity of
    // the prepared copy (which changes with every new prefix) only decides generator re-runs.
    const hasNewArg =
      previous === null ||
      (result.currentArg?.source ?? null) !== (previous.currentArg?.source ?? null) ||
      originOf(result.node) !== originOf(previous.node);
    const replaced = this.generators.update(result, previous, this.generatorContext(result));
    if (!edit.contextOnly) {
      if (this.revealWhenLoaded !== null) {
        // Typing on after a show key whose list was still loading: the popup counts as shown.
        this.visibility = "visible";
        this.revealWhenLoaded = null;
      }
      this.visibility = visibilityAfterParse(this.visibility, {
        hasNewArg,
        insertionRetriggered: this.generators.replaced(replaced, this.lastInserted?.generator),
        backspacedIntoPreviousToken: edit.backspacedIntoPreviousToken,
        largeChange: edit.largeChange,
        justInserted: this.justInserted,
        onlyShowOnTab: booleanSetting(this.settings, SETTING.onlyShowOnTab),
      });
      if (hasNewArg) {
        this.userFuzzy = booleanSetting(this.settings, SETTING.fuzzySearch);
      }
      this.justInserted = false;
    }
    this.parse = result;
    this.fuzzy = this.fuzzyFor(result);
    this.syncGenerators();
    this.updateLoading();
    this.recompute();
    this.revealIfLoaded();
  }

  /**
   * Generators run programs in the user's directory (`make -qp` evaluates the Makefile), so they
   * only run for a popup that is to be shown: not while it is dismissed with Esc, hidden after a
   * paste or an insertion, or waiting for Tab with onlyShowOnTab. They start when it is shown.
   */
  private generatorsMayRun(): boolean {
    return !this.disposed && (this.visibility === "visible" || this.revealWhenLoaded !== null);
  }

  /** Starts the argument's generators while they may run; otherwise holds back unfinished ones. True if anything changed. */
  private syncGenerators(): boolean {
    return this.generatorsMayRun() ? this.generators.start() : this.generators.pause();
  }

  /** onlyShowOnTab: Tab reveals the list, or completes straight away when there is one entry. */
  private revealForTab(): void {
    const selected = this.items[this.selectedIndex];
    if (this.items.length === 1 && selected) {
      this.insertItem(selected, false);
    } else if (this.items.length > 0) {
      this.setVisibility("visible");
    }
  }

  /** Shows the popup a show key asked for, once the generators it started have finished. */
  private revealIfLoaded(): void {
    const reveal = this.revealWhenLoaded;
    if (reveal === null || this.generators.loading || this.parsePending) {
      return;
    }
    this.revealWhenLoaded = null;
    if (reveal === "tab") {
      this.revealForTab();
    } else if (this.items.length > 0) {
      this.setVisibility("visible");
    }
  }

  // ---- Generators and history ---------------------------------------------------------------

  private generatorContext(result: ParseResult): GeneratorContext {
    const context = this.shellContext;
    const env = { ...(context?.env ?? {}) };
    if (env.HOME === undefined && context?.home) {
      env.HOME = context.home;
    }
    return {
      tokens: result.tokens.slice(result.commandIndex),
      searchTerm: result.searchTerm,
      cwd: context?.cwd ?? "",
      env,
      shell: context?.shell ?? "",
      isDangerous: Boolean(result.currentArg?.isDangerous),
      annotations: result.annotations,
      currentArg: result.currentArg,
    };
  }

  private services(): GeneratorServices {
    return {
      executeCommand: (cwd, timeoutMs) => this.executeCommand(cwd, timeoutMs),
      cache: this.generatorCache,
      scriptTimeout: numberSetting(this.settings, SETTING.scriptTimeout, 5_000),
      autoCache: booleanSetting(this.settings, SETTING.autoCache),
      historyValues: (context) => this.history.values(context),
    };
  }

  private setHistoryMode(enabled: boolean): void {
    this.historyMode = enabled;
    this.recompute();
  }

  /**
   * Whether the whole buffer, text after the cursor included, is more than one simple command.
   * A newline runs all of it, and only the command being completed has been checked for danger,
   * so no row may run such a line (unless the user allows dangerous commands to run at once).
   */
  private isCompoundLine(): boolean {
    return splitCommands(this.buffer, this.shellContext?.shell ?? "").length > 1;
  }

  /** History entries continuing the line; the first use reads the shell's history, then refreshes. */
  private historyCandidates(): Item[] {
    const version = this.history.version;
    void this.history.load().then(() => {
      if (this.history.version !== version && this.parse !== null) {
        this.recompute();
      }
    });
    return historyItems(this.history.entries(), this.historyPrefix());
  }

  /** The buffer up to where the current word's text starts (inside any opening quote). */
  private historyPrefix(): string {
    const token = this.line?.command.tokens.at(-1);
    return this.buffer.slice(0, token === undefined ? this.cursor : (token.offsets[0] ?? token.end));
  }

  // ---- The list -----------------------------------------------------------------------------

  private recompute(): void {
    const result = this.parse;
    if (result === null) {
      this.publish();
      return;
    }
    let list: RankedItem[];
    try {
      this.compoundLine = this.isCompoundLine();
      list = buildList(result, this.generators.current, {
        settings: this.settings,
        recency: this.recency,
        fuzzy: this.fuzzy,
        historyMode: this.historyMode,
        history: () => this.historyCandidates(),
        compoundLine: this.compoundLine,
      });
    } catch (error) {
      // Spec data is arbitrary; a malformed suggestion must not wedge the popup.
      console.error("Building the suggestion list failed", error);
      list = [];
    }

    // While generators are still loading (and before the loading indicator is due), keep the
    // list that is on screen rather than flashing a partial one. It keeps its own context, so
    // accepting from it still inserts the right text.
    if (
      this.generators.loading &&
      !this.loading &&
      this.state.visible &&
      this.visibility === "visible" &&
      this.items.length > 0
    ) {
      this.publish();
      return;
    }

    const selection = reselect(
      this.items,
      this.selectedIndex,
      this.hasChangedIndex && this.visibility === "visible",
      list,
    );
    this.items = list;
    this.selectedIndex = selection.index;
    this.hasChangedIndex = selection.userMoved;
    this.listContext = {
      result,
      token: this.line?.command.tokens.at(-1) ?? null,
      buffer: this.buffer,
      fuzzy: this.fuzzy,
    };
    this.publish();
  }

  // ---- Loading ------------------------------------------------------------------------------

  private isIdle(): boolean {
    return !this.parsePending && !this.generators.loading;
  }

  /** Raises `loading` once work has been pending for 200 ms; clears it when nothing is. */
  private updateLoading(): void {
    if (this.isIdle()) {
      this.clearLoadingTimer();
      this.loading = false;
      this.resolveIdle();
      return;
    }
    if (!this.loading && this.loadingTimer === null) {
      this.loadingTimer = setTimeout(() => {
        this.loadingTimer = null;
        if (!this.isIdle() && !this.disposed) {
          this.loading = true;
          if (this.revealWhenLoaded !== null) {
            // A show key is waiting on slow generators: show the indicator meanwhile. What the key
            // does once they finish stands (onlyShowOnTab's Tab still completes a single entry).
            this.visibility = "visible";
          }
          this.recompute();
        }
      }, LOADING_DELAY_MS);
    }
  }

  private clearLoadingTimer(): void {
    if (this.loadingTimer !== null) {
      clearTimeout(this.loadingTimer);
      this.loadingTimer = null;
    }
  }

  private resolveIdle(): void {
    for (const resolve of this.idleWaiters.splice(0)) {
      resolve();
    }
  }

  // ---- Actions ------------------------------------------------------------------------------

  private setVisibility(visibility: Visibility): void {
    this.visibility = visibility;
    if (this.syncGenerators()) {
      this.updateLoading();
      this.recompute();
      return;
    }
    this.publish();
  }

  private navigate(delta: number): void {
    const move = navigateTo(
      this.selectedIndex,
      delta,
      this.items.length,
      booleanSetting(this.settings, SETTING.scrollWrapAround),
    );
    if (move.kind === "beforeFirst") {
      if (booleanSetting(this.settings, SETTING.navigateToHistory)) {
        this.setHistoryMode(!this.historyMode);
      } else {
        // Up on the first row hides; the next Up reaches the shell's own history.
        this.setVisibility("hiddenUntilKeypress");
      }
      return;
    }
    this.hasChangedIndex = move.index !== this.selectedIndex;
    this.selectedIndex = move.index;
    this.publish();
  }

  private insertionContext(): InsertionContext | null {
    const list = this.listContext;
    if (list === null) {
      return null;
    }
    return {
      searchTerm: list.result.searchTerm,
      buffer: list.buffer,
      token: list.token,
      fuzzy: list.fuzzy,
      preferVerbose: booleanSetting(this.settings, SETTING.preferVerboseSuggestions),
      shell: this.shellContext?.shell ?? "",
      insertSpace: booleanSetting(this.settings, SETTING.insertSpaceAutomatically, true),
    };
  }

  private send(text: string, insertionBuffer: string): void {
    if (this.sessionId !== null && text !== "") {
      void this.bridge
        .call("shell.insert", { sessionId: this.sessionId, text, insertionBuffer })
        .catch(() => undefined);
    }
  }

  /** Nothing to insert, or an insertion that was refused: the UI shakes the list. */
  private shake(): void {
    this.shakeCount += 1;
    this.publish();
  }

  private insertItem(item: RankedItem, execute: boolean): void {
    const context = this.insertionContext();
    const list = this.listContext;
    if (context === null || list === null) {
      return;
    }
    const bytes = insertionBytes(item, fullInsertionText(item, context, execute), context, true);
    if (bytes === null) {
      this.shake();
      return;
    }
    this.send(bytes, list.buffer);
    const name = item.names[0];
    if (name !== undefined) {
      this.recency.record(list.result.tokens[list.result.commandIndex] ?? "", name);
    }
    this.lastInserted = item;
    this.justInserted = true;
    this.setVisibility("hiddenByInsertion");
  }

  /** Tab: inserts the shared prefix (or the item); false when there is nothing to insert. */
  private insertCommonPrefix(): boolean {
    const context = this.insertionContext();
    const list = this.listContext;
    const selected = this.items[this.selectedIndex];
    if (context === null || list === null || selected === undefined) {
      return false;
    }
    const outcome = commonPrefixOutcome(this.items, this.selectedIndex, context);
    if (outcome.kind === "none") {
      return false;
    }
    if (outcome.kind === "full") {
      this.insertItem(selected, false);
      return true;
    }
    const bytes = insertionBytes(selected, outcome.text, context, false);
    if (bytes === null) {
      return false;
    }
    this.send(bytes, list.buffer);
    // A partial insertion keeps the list up, and must not look like a paste on the next parse.
    this.justInserted = true;
    return true;
  }

  /**
   * The line is gone (it ran, or there is no line to edit): forget it too, so a later `session`
   * or `settings` event cannot parse it again or offer it at the next prompt.
   */
  private clearLine(): void {
    this.buffer = "";
    this.cursor = 0;
    this.reset();
  }

  /** Back to the initial state for a new line: hidden until the next keystroke. */
  private reset(): void {
    this.parseSequence += 1;
    this.parsePending = false;
    this.pendingEdit = null;
    this.line = null;
    this.lineKey = "";
    this.parse = null;
    this.generators.clear();
    this.visibility = "hiddenUntilKeypress";
    this.revealWhenLoaded = null;
    this.lastInserted = null;
    this.justInserted = false;
    this.items = [];
    this.listContext = null;
    this.selectedIndex = 0;
    this.hasChangedIndex = false;
    this.historyMode = false;
    this.userFuzzy = booleanSetting(this.settings, SETTING.fuzzySearch);
    this.fuzzy = false;
    this.updateLoading();
    this.publish();
  }

  // ---- Output -------------------------------------------------------------------------------

  private buildState(): CoreState {
    return coreStateOf({
      sessionId: this.sessionId,
      context: this.shellContext,
      settings: this.settings,
      visibility: this.visibility,
      items: this.items,
      selectedIndex: this.selectedIndex,
      listResult: this.listContext?.result ?? null,
      parse: this.parse,
      loading: this.loading,
      historyMode: this.historyMode,
      descriptionPopout: this.descriptionPopout,
      scale: this.scale,
      shakeCount: this.shakeCount,
    });
  }

  private publish(): void {
    if (this.disposed) {
      return;
    }
    this.state = this.buildState();
    this.updateIntercept();
    for (const listener of [...this.listeners]) {
      try {
        listener(this.state);
      } catch (error) {
        console.error("Core state listener failed", error);
      }
    }
  }

  /** Tells the session's wrapper which keys to take whenever that changes (UI doc §3.3). */
  private updateIntercept(): void {
    if (this.sessionId === null) {
      return;
    }
    const params = interceptFor(
      this.sessionId,
      this.state,
      this.visibility,
      this.generators.pending || this.revealWhenLoaded !== null,
    );
    const key = JSON.stringify(params);
    if (key !== this.lastIntercept) {
      this.lastIntercept = key;
      void this.bridge.call("shell.setIntercept", params).catch(() => undefined);
    }
  }
}
