/**
 * The contract between the web popup and the native Figo app.
 *
 * The app hosts this page in a transparent WKWebView. JavaScript calls native code through
 * `NativeBridge.call`, and native code pushes events that are delivered through
 * `NativeBridge.on`. Everything crossing the boundary is plain JSON.
 *
 * Static content is served by the app under custom URL schemes rather than through calls:
 *
 *   figo://app/…                 this page and its assets
 *   figo://specs/index.json      { completions: string[], diffVersionedCompletions: string[] }
 *   figo://specs/<name>.js       a compiled completion spec (ES module, default export = Fig.Spec).
 *                                Specs in ~/.config/figo/specs win over the bundled ones.
 *   figo://themes/<name>.json    a theme file; ~/.config/figo/themes wins over the bundled ones
 *   fig://icon?type=<ext>        the system icon for a file type, as PNG
 *   fig://path/<absolute path>   the Finder icon of that file or folder, as PNG
 */

/** Identifies one terminal session (one shell running inside the Figo pty wrapper). */
export type SessionId = string;

/** What is known about the shell of a session. Sent whenever any of it changes. */
export interface ShellContext {
  sessionId: SessionId;
  /** `zsh`, `bash` or `fish`. */
  shell: string;
  /** Absolute path of the shell binary, e.g. `/bin/zsh`. */
  shellPath?: string;
  /** Process id of the shell. */
  pid?: number;
  /** The shell's current working directory. */
  cwd: string;
  /** Login name of the user the shell runs as. */
  user?: string;
  /** The user's home directory. */
  home: string;
  /** The shell's exported environment as of the last prompt. */
  env: Record<string, string>;
  /** Raw output of the shell's `alias` builtin as of the last prompt; format differs per shell. */
  aliases: string;
  /** Bundle identifier of the terminal emulator when known, e.g. `com.mitchellh.ghostty`. */
  terminal?: string;
}

export interface DirectoryEntry {
  name: string;
  /** For symbolic links this describes the target. `other` covers sockets, devices and dangling links. */
  kind: "file" | "directory" | "other";
  isSymlink: boolean;
}

export interface ProcessResult {
  stdout: string;
  stderr: string;
  /** The exit status, or 128 + signal number when the process was killed by a signal. */
  exitCode: number;
}

/** Flat map of dotted setting keys to JSON values, e.g. `{ "autocomplete.theme": "dracula" }`. */
export type Settings = Record<string, unknown>;

export interface AppInfo {
  version: string;
  home: string;
  user: string;
  /** e.g. `15.5.0`. */
  macosVersion: string;
  settings: Settings;
  /** Names of every available theme file (without `.json`), bundled and user-provided. */
  themes: string[];
}

/** Requests the popup can make. Each resolves with `result`, or rejects with an `Error`. */
export interface NativeRequests {
  /** Called once when the page has loaded and subscribed to events. */
  "app.ready": { params: Record<string, never>; result: AppInfo };

  /** Appends a line to the app's log. */
  "app.log": { params: { level: "debug" | "info" | "warn" | "error"; message: string }; result: null };

  /**
   * Publishes a JSON description of what the popup is currently showing, which the app exposes
   * through `figo debug status`. Used by automated tests; has no effect on behaviour.
   */
  "app.reportState": { params: { state: unknown }; result: null };

  /**
   * Sizes the popup window and places it relative to the terminal's text cursor.
   *
   * `width`/`height` are the size of the page content in CSS pixels. A width or height of 0 or
   * 1 hides the window. `anchorX` shifts the window horizontally from the caret (negative =
   * left); `offsetFromBaseline` shifts it vertically away from the caret rectangle. With
   * `dryRun` nothing moves and only the answer is computed.
   */
  "window.position": {
    params: { width: number; height: number; anchorX: number; offsetFromBaseline: number; dryRun?: boolean };
    result: {
      /** The window is (or would be) placed above the caret because it does not fit below. */
      isAbove: boolean;
      /** The window would extend past the right edge of the screen at the caret's x position. */
      isClipped: boolean;
    };
  };

  /**
   * Types into the session's shell as if the user had.
   *
   * `text` may contain `\b` (0x08, delete backwards), `ESC [ D` / `ESC [ C` (cursor left/right)
   * and `\n` (run the command). `insertionBuffer` is the edit buffer the insertion was computed
   * against: if the user has typed further in the meantime the wrapper reconciles first.
   */
  "shell.insert": { params: { sessionId: SessionId; text: string; insertionBuffer?: string }; result: null };

  /**
   * Tells the pty wrapper of `sessionId` which keys to take away from the shell. Every other
   * session stops intercepting.
   *
   * While `interceptBound` is true every key in `bindings` is swallowed and reported through
   * the `keybinding` event with its action. While only `interceptGlobal` is true (popup hidden
   * but suggestions exist) only keys bound to `showAutocomplete` / `toggleAutocomplete` are.
   * `bindings` maps a key such as `enter`, `shift+tab` or `control+k` to an action id; the
   * action `ignore` unbinds a key.
   */
  "shell.setIntercept": {
    params: {
      sessionId: SessionId;
      interceptBound: boolean;
      interceptGlobal: boolean;
      bindings: Record<string, string>;
    };
    result: null;
  };

  /**
   * Runs a program with the session shell's environment and returns its output. The program is
   * executed directly, not through a shell, by the pty wrapper of that session (so it has the
   * terminal's file-access permissions rather than Figo's).
   *
   * `executable` is looked up in the shell's `PATH` unless it contains a slash. `cwd` defaults
   * to the shell's working directory, and is also used when the given directory does not exist.
   * In `env`, `null` removes a variable. Rejects when the timeout (default 60 000 ms) expires.
   */
  "process.run": {
    params: {
      sessionId: SessionId;
      executable: string;
      args: string[];
      cwd?: string;
      env?: Record<string, string | null>;
      timeoutMs?: number;
    };
    result: ProcessResult;
  };

  /**
   * Lists a directory through the session's pty wrapper. `path` may start with `~` and may be
   * relative to the shell's working directory. Entries are unsorted and include dotfiles but not
   * `.` or `..`. Rejects when the directory cannot be read.
   */
  "fs.list": { params: { sessionId: SessionId; path: string }; result: { entries: DirectoryEntry[] } };

  /** Persists one setting; `value: undefined` (key omitted) removes it. A `settings` event follows. */
  "settings.set": { params: { key: string; value?: unknown }; result: null };
}

/** Events the app pushes to the popup. */
export interface NativeEvents {
  /** Sent before the first `editBuffer` of a session and whenever its context changes. */
  session: ShellContext;

  /**
   * The command line being edited in the focused session changed. `cursor` is an index into
   * `buffer` in UTF-16 code units. `buffer: null` means there is currently no command line to
   * complete (a command is running, a full-screen program is open, …) and the popup must hide.
   */
  editBuffer: { sessionId: SessionId; buffer: string | null; cursor: number };

  /** The shell drew a fresh prompt. */
  prompt: { sessionId: SessionId };

  /** The shell started running a command. */
  preExec: { sessionId: SessionId };

  /** A command finished. `command` is the command line as it was submitted. */
  postExec: { sessionId: SessionId; command: string; exitCode: number };

  /** A key bound through `shell.setIntercept` was pressed and swallowed. */
  keybinding: { sessionId: SessionId; action: string };

  /** The settings file changed; carries the complete new settings. */
  settings: { settings: Settings };

  /** The popup window was hidden by the app (focus moved to another app, for instance). */
  windowHidden: Record<string, never>;
}

export interface NativeBridge {
  call<Method extends keyof NativeRequests>(
    method: Method,
    params: NativeRequests[Method]["params"],
  ): Promise<NativeRequests[Method]["result"]>;

  /** Subscribes to an event; returns a function that unsubscribes. */
  on<Event extends keyof NativeEvents>(event: Event, listener: (payload: NativeEvents[Event]) => void): () => void;
}
