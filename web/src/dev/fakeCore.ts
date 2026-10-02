import type { ActionId, Core, CoreState, Suggestion } from "../core/contract";
import { HISTORY, type Scenario, type ScenarioSuggestion } from "./scenarios";

const SIZE_STEP = 1.1;

function displayed(suggestion: ScenarioSuggestion): string[] {
  return suggestion.displayName ? [suggestion.displayName] : suggestion.names;
}

/** Prefix filter with the match range the real core would report. */
function filter(suggestions: ScenarioSuggestion[], query: string): Suggestion[] {
  const lower = query.toLowerCase();
  const result: Suggestion[] = [];
  for (const suggestion of suggestions) {
    const names = displayed(suggestion);
    const nameIndex = names.findIndex((name) => name.toLowerCase().startsWith(lower));
    if (nameIndex >= 0) {
      result.push({ ...suggestion, match: { nameIndex, ranges: query ? [[0, query.length]] : [] } });
    }
  }
  return result;
}

function longestCommonPrefix(values: string[]): string {
  let prefix = values[0] ?? "";
  for (const value of values) {
    while (!value.startsWith(prefix)) {
      prefix = prefix.slice(0, -1);
    }
  }
  return prefix;
}

function typeGroup(type: Suggestion["type"]): string {
  return type === "file" ? "folder" : type;
}

/** What Tab would insert beyond the query, as the core reports it. */
function commonPrefix(suggestions: Suggestion[], selectedIndex: number, query: string): [number, number] | null {
  const selected = suggestions[selectedIndex];
  if (!selected || selected.type === "special" || selected.type === "auto-execute") {
    return null;
  }
  const names = suggestions
    .filter((s) => typeGroup(s.type) === typeGroup(selected.type))
    .map((s) => (s.names[0] ?? "").toLowerCase());
  if (names.length < 2) {
    return null;
  }
  const prefix = longestCommonPrefix(names);
  return prefix.length > query.length ? [query.length, prefix.length] : null;
}

/**
 * A stand-in for the completion core: a fixed scenario, filtered by what is typed, with the core's
 * key actions implemented just far enough to try the popup in a browser.
 */
export class FakeCore implements Core {
  private scenario!: Scenario;
  private query = "";
  private state!: CoreState;
  private readonly listeners = new Set<(state: CoreState) => void>();
  /** Lines "run" in the fake terminal, shown above the prompt. */
  output: string[] = [];

  constructor(
    scenario: Scenario,
    private readonly onNavigate: (scenarioId: string) => void = () => {},
  ) {
    this.load(scenario);
  }

  load(scenario: Scenario): void {
    this.scenario = scenario;
    this.query = scenario.query ?? "";
    this.output = [];
    this.state = {
      sessionId: "dev",
      visible: true,
      suggestions: [],
      selectedIndex: 0,
      commonPrefix: null,
      loading: scenario.loading ?? false,
      argument: null,
      historyMode: false,
      descriptionPopout: scenario.descriptionPopout ?? scenario.settings?.["autocomplete.alwaysShowDescription"] === true,
      scale: 1,
      shakeCount: 0,
      settings: scenario.settings ?? {},
    };
    this.refilter(true);
  }

  getScenario(): Scenario {
    return this.scenario;
  }

  /** Replaces the scenario's theme setting (the harness's theme picker); null restores it. */
  setThemeOverride(theme: string | null): void {
    const settings = { ...this.scenario.settings };
    if (theme !== null) {
      settings["autocomplete.theme"] = theme;
    }
    this.set({ settings });
  }

  /** The text after the prompt. */
  getLine(): string {
    return this.scenario.command + this.query;
  }

  getState(): CoreState {
    return this.state;
  }

  subscribe(listener: (state: CoreState) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  dispose(): void {
    this.listeners.clear();
  }

  type(text: string): void {
    this.query += text;
    this.refilter(true, { visible: true });
  }

  backspace(): void {
    if (this.query === "") {
      return;
    }
    this.query = this.query.slice(0, -1);
    this.refilter(true, { visible: true });
  }

  dispatch(action: ActionId): void {
    const { suggestions, selectedIndex, visible } = this.state;
    // Upstream ignores every action while there is nothing selected.
    if (suggestions.length === 0 && action !== "showAutocomplete" && action !== "toggleAutocomplete") {
      return;
    }
    switch (action) {
      case "navigateUp":
        if (selectedIndex === 0) {
          this.set({ visible: false });
        } else {
          this.select(selectedIndex - 1);
        }
        break;
      case "navigateDown":
        this.select(Math.min(suggestions.length - 1, selectedIndex + 1));
        break;
      case "insertSelected":
      case "insertSelectedAndExecute":
        this.insert(selectedIndex);
        break;
      case "insertCommonPrefix":
      case "insertCommonPrefixOrNavigateDown":
      case "insertCommonPrefixOrInsertSelected":
        this.insertCommonPrefix(action);
        break;
      case "hideAutocomplete":
        this.set({ visible: false });
        break;
      case "showAutocomplete":
        this.set({ visible: true });
        break;
      case "toggleAutocomplete":
        this.set({ visible: !visible });
        break;
      case "toggleDescription":
        if (this.state.settings["autocomplete.alwaysShowDescription"] !== true) {
          this.set({ descriptionPopout: !this.state.descriptionPopout });
        }
        break;
      case "toggleHistoryMode":
        this.set({ historyMode: !this.state.historyMode });
        this.refilter(true);
        break;
      case "increaseSize":
        this.set({ scale: this.state.scale * SIZE_STEP });
        break;
      case "decreaseSize":
        this.set({ scale: this.state.scale / SIZE_STEP });
        break;
      case "execute":
      case "toggleFuzzySearch":
        break;
    }
  }

  insert(index: number): void {
    const item = this.state.suggestions[index];
    if (!item) {
      return;
    }
    const name = item.names[0] ?? "";
    const next = this.scenario.next?.[name];
    if (next) {
      this.onNavigate(next);
      return;
    }
    if (item.type === "auto-execute") {
      this.run();
      return;
    }
    this.query = name;
    this.refilter(true, { visible: false });
  }

  /** Enter while the popup is hidden: the line "runs" and a fresh prompt appears. */
  run(): void {
    this.output.push(this.getLine());
    this.query = "";
    this.refilter(true, { visible: false });
  }

  private insertCommonPrefix(action: ActionId): void {
    const { suggestions, selectedIndex, commonPrefix: range } = this.state;
    if (suggestions.length === 1) {
      this.insert(0);
      return;
    }
    const name = suggestions[selectedIndex]?.names[0];
    if (range && name) {
      this.query = name.slice(0, range[1]);
      this.refilter(false);
      return;
    }
    if (action === "insertCommonPrefixOrNavigateDown") {
      this.dispatch("navigateDown");
    } else if (action === "insertCommonPrefixOrInsertSelected") {
      this.insert(selectedIndex);
    } else {
      this.set({ shakeCount: this.state.shakeCount + 1 });
    }
  }

  private select(index: number): void {
    this.set({
      selectedIndex: index,
      commonPrefix: commonPrefix(this.state.suggestions, index, this.query),
    });
  }

  private refilter(resetSelection: boolean, extra: Partial<CoreState> = {}): void {
    const source = this.state.historyMode ? HISTORY : this.scenario.suggestions;
    const suggestions = filter(source, this.query);
    const previous = this.state.suggestions[this.state.selectedIndex];
    let selectedIndex = 0;
    if (!resetSelection && previous) {
      selectedIndex = Math.max(0, suggestions.findIndex((s) => s.names[0] === previous.names[0]));
    }
    this.set({
      suggestions,
      selectedIndex,
      commonPrefix: commonPrefix(suggestions, selectedIndex, this.query),
      argument: suggestions.length === 0 ? (this.scenario.argument ?? null) : null,
      ...extra,
    });
  }

  private set(patch: Partial<CoreState>): void {
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) {
      listener(this.state);
    }
  }
}
