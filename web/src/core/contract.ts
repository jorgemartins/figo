/**
 * The contract between the headless completion core and the popup UI.
 *
 * The core owns everything that is not pixels: parsing the command line, loading specs, running
 * generators, ranking, the visibility state machine, the selection, key actions and insertion.
 * It talks to the app through `NativeBridge`. The UI renders `CoreState`, reports clicks, and
 * handles layout (measuring itself, positioning the window, themes).
 */
import type { NativeBridge, SessionId, Settings } from "../bridge/contract";

export type SuggestionType =
  | "folder"
  | "file"
  | "arg"
  | "subcommand"
  | "option"
  | "special"
  | "mixin"
  | "shortcut"
  | "history"
  /** Accepting it runs the command line. */
  | "auto-execute";

/** An argument a subcommand or option takes, shown dimmed after its name: `[package...]`. */
export interface ArgumentHint {
  name: string;
  isOptional: boolean;
  isVariadic: boolean;
}

export interface Suggestion {
  type: SuggestionType;
  /** Every name the item answers to, in spec order, e.g. `["install", "i"]`. Never empty. */
  names: string[];
  /** Shown instead of `names` when present. */
  displayName?: string;
  description?: string;
  /**
   * As written in the spec: a `fig://` URL (`fig://icon?type=npm`, `fig://template?color=…&badge=…`,
   * `fig://path/…`), any other URL, or a short string such as an emoji. Undefined means "use the
   * default icon for `type`". Only `fig:`, `figo:` and `data:` URLs are drawn; any other URL gets
   * the default icon. Generators may give only `fig:` URLs and text.
   */
  icon?: string;
  /** Only named arguments of subcommands and options. */
  args?: ArgumentHint[];
  isDangerous?: boolean;
  /**
   * Which characters of the displayed text matched the query, as [start, end) ranges in UTF-16
   * units. `nameIndex` says which entry of `names` they refer to (always 0 for `displayName`).
   * Empty when nothing was typed.
   */
  match: { nameIndex: number; ranges: Array<[number, number]> };
}

/**
 * The argument being completed. Shown on its own when there is nothing to suggest, and in the
 * footer when the selected suggestion has no description.
 */
export interface ArgumentInfo {
  name: string;
  description?: string;
}

export interface CoreState {
  /** The session whose command line is being completed, if any. */
  sessionId: SessionId | null;
  /**
   * Whether the popup should be on screen. False covers every hidden state (nothing to complete,
   * dismissed with Esc, just inserted, …); the UI then renders nothing and sizes the window away.
   */
  visible: boolean;
  suggestions: Suggestion[];
  /** Always a valid index into `suggestions` when it is non-empty; 0 otherwise. */
  selectedIndex: number;
  /**
   * The part of the selected suggestion's first name that Tab would insert beyond what is typed,
   * as a [start, end) range to underline, or null when there is no common prefix to insert.
   */
  commonPrefix: [number, number] | null;
  /** Generators have been running for a while: show the loading indicator instead of the list. */
  loading: boolean;
  /** The argument at the cursor when the spec gives it a name; null otherwise. */
  argument: ArgumentInfo | null;
  /** The list is showing shell history (wider popup). */
  historyMode: boolean;
  /** The description is shown in a side panel rather than in the footer. */
  descriptionPopout: boolean;
  /** Session-only size factor changed by the increaseSize / decreaseSize actions; 1 by default. */
  scale: number;
  /** Increments each time the UI should play the "nothing to insert" shake. */
  shakeCount: number;
  /** The current settings, for the UI's own keys (theme, width, height, fonts, …). */
  settings: Settings;
}

/**
 * Ids of the actions a key can be bound to. They arrive from the pty wrapper as `keybinding`
 * events and are handled entirely inside the core.
 */
export type ActionId =
  | "insertSelected"
  | "insertCommonPrefix"
  | "insertCommonPrefixOrNavigateDown"
  | "insertCommonPrefixOrInsertSelected"
  | "insertSelectedAndExecute"
  | "execute"
  | "hideAutocomplete"
  | "showAutocomplete"
  | "toggleAutocomplete"
  | "navigateUp"
  | "navigateDown"
  | "toggleDescription"
  | "toggleHistoryMode"
  | "toggleFuzzySearch"
  | "increaseSize"
  | "decreaseSize";

export interface Core {
  getState(): CoreState;
  /** Calls `listener` after every state change; returns a function that unsubscribes. */
  subscribe(listener: (state: CoreState) => void): () => void;
  /** Performs an action as if its key had been pressed. */
  dispatch(action: ActionId): void;
  /** Inserts the suggestion at `index` (a click on its row). */
  insert(index: number): void;
  /** Stops listening to the bridge and cancels pending work. */
  dispose(): void;
}

export interface CoreOptions {
  /**
   * Loads a compiled spec module by name (`git`, `aws/s3`). Defaults to
   * `import("figo://specs/<name>.js")`; tests substitute a loader that reads from disk.
   */
  importSpec?: (name: string) => Promise<unknown>;
  /** Loads the spec index. Defaults to fetching `figo://specs/index.json`. */
  loadIndex?: () => Promise<{ completions: string[]; diffVersionedCompletions: string[] }>;
  /** Key-value storage for what should survive restarts (recency of picked suggestions). */
  storage?: Pick<Storage, "getItem" | "setItem">;
}

export type CreateCore = (bridge: NativeBridge, options?: CoreOptions) => Core;
