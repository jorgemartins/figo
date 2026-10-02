/**
 * A scriptable stand-in for the Figo app, for tests of the core and the UI.
 *
 *   const bridge = new FakeBridge();
 *   bridge.settings = { "autocomplete.fuzzySearch": true };   // what app.ready returns
 *   bridge.setDirectory("/Users/test/", ["Sites/", "notes.txt"]);
 *   bridge.onProcess("git help -a", { stdout: "…" });
 *   const core = createCore(bridge, diskSpecs());
 *   bridge.startSession({ cwd: "/Users/test" });
 *   bridge.type("cd ");                     // an editBuffer event
 *   await whenIdle(core);
 *   bridge.press("insertSelected");         // a keybinding event
 *   bridge.inserts();                       // ["Sites/"]
 *   bridge.echoLastInsert();                // the shell echoes the insertion back
 *   bridge.lastIntercept(); bridge.calls; bridge.unmatchedProcesses;
 */
import type {
  AppInfo,
  DirectoryEntry,
  NativeBridge,
  NativeEvents,
  NativeRequests,
  ProcessResult,
  SessionId,
  Settings,
  ShellContext,
} from "../../bridge/contract";

export interface RecordedCall {
  method: keyof NativeRequests;
  params: unknown;
}

export type ProcessParams = NativeRequests["process.run"]["params"];
/** Exact command line (`git help -a`), a pattern tested against it, or a predicate. */
export type ProcessMatcher = string | RegExp | ((params: ProcessParams) => boolean);
export type ProcessReply =
  Partial<ProcessResult> | ((params: ProcessParams) => Partial<ProcessResult> | Promise<Partial<ProcessResult>>);

type Listener = (payload: never) => void;

function commandLine(params: ProcessParams): string {
  return [params.executable, ...params.args].join(" ");
}

function withSlash(path: string): string {
  return path.endsWith("/") ? path : `${path}/`;
}

export class FakeBridge implements NativeBridge {
  readonly calls: RecordedCall[] = [];
  /** process.run calls nothing was scripted for (they answer exit status 127). */
  readonly unmatchedProcesses: ProcessParams[] = [];
  settings: Settings = {};
  appInfo: Omit<AppInfo, "settings"> = {
    version: "0.0.0-test",
    home: "/Users/test",
    user: "test",
    macosVersion: "15.5.0",
    themes: ["dark", "light"],
  };

  private readonly listeners = new Map<string, Set<Listener>>();
  private readonly directories = new Map<string, DirectoryEntry[]>();
  private readonly processes: Array<{ matcher: ProcessMatcher; reply: ProcessReply }> = [];
  private session: ShellContext | null = null;
  private buffer = "";
  private cursor = 0;

  // ---- NativeBridge -------------------------------------------------------------------------

  call<Method extends keyof NativeRequests>(
    method: Method,
    params: NativeRequests[Method]["params"],
  ): Promise<NativeRequests[Method]["result"]> {
    this.calls.push({ method, params });
    return this.answer(method, params) as Promise<NativeRequests[Method]["result"]>;
  }

  on<Event extends keyof NativeEvents>(event: Event, listener: (payload: NativeEvents[Event]) => void): () => void {
    let set = this.listeners.get(event);
    if (!set) {
      set = new Set();
      this.listeners.set(event, set);
    }
    set.add(listener as Listener);
    return () => {
      set.delete(listener as Listener);
    };
  }

  // ---- Scripting ----------------------------------------------------------------------------

  /** Delivers an event to the core, as the app would. */
  emit<Event extends keyof NativeEvents>(event: Event, payload: NativeEvents[Event]): void {
    for (const listener of [...(this.listeners.get(event) ?? [])]) {
      (listener as (payload: NativeEvents[Event]) => void)(payload);
    }
  }

  /** Scripts `fs.list` for an absolute directory. Names ending in `/` are directories. */
  setDirectory(path: string, entries: ReadonlyArray<string | DirectoryEntry>): this {
    this.directories.set(
      withSlash(path),
      entries.map((entry) =>
        typeof entry === "string"
          ? { name: entry.replace(/\/$/, ""), kind: entry.endsWith("/") ? "directory" : "file", isSymlink: false }
          : entry,
      ),
    );
    return this;
  }

  /** Scripts `process.run`; later scripts win over earlier ones for the same command. */
  onProcess(matcher: ProcessMatcher, reply: ProcessReply): this {
    this.processes.unshift({ matcher, reply });
    return this;
  }

  /** Emits `session` with sensible defaults and makes it the session `type` and `press` use. */
  startSession(context: Partial<ShellContext> = {}): ShellContext {
    const home = context.home ?? this.appInfo.home;
    const session: ShellContext = {
      sessionId: "session-1",
      shell: "zsh",
      shellPath: "/bin/zsh",
      cwd: home,
      home,
      user: this.appInfo.user,
      env: { HOME: home, PATH: "/usr/bin:/bin" },
      aliases: "",
      ...context,
    };
    this.session = session;
    this.emit("session", session);
    return session;
  }

  /** Changes the current session's context (cwd, aliases, …) and re-emits `session`. */
  updateSession(changes: Partial<ShellContext>): ShellContext {
    const session = { ...this.requireSession(), ...changes };
    this.session = session;
    this.emit("session", session);
    return session;
  }

  /** Emits `editBuffer` for the current session; the cursor defaults to the end. */
  type(buffer: string | null, cursor = buffer?.length ?? 0): void {
    this.buffer = buffer ?? "";
    this.cursor = buffer === null ? 0 : cursor;
    this.emit("editBuffer", { sessionId: this.requireSession().sessionId, buffer, cursor });
  }

  /**
   * Plays the last `shell.insert` into the line the way the shell would (backspaces, cursor
   * moves, text) and emits the resulting `editBuffer`; a newline runs the line, emitting
   * `preExec` instead. Returns the new line.
   */
  echoLastInsert(): { buffer: string; cursor: number; executed: boolean } {
    const insert = this.callsTo("shell.insert").at(-1);
    if (!insert) {
      throw new Error("Nothing was inserted");
    }
    let buffer = insert.insertionBuffer ?? this.buffer;
    let cursor =
      insert.insertionBuffer !== undefined && insert.insertionBuffer !== this.buffer ? buffer.length : this.cursor;
    let executed = false;
    const text = insert.text;
    for (let i = 0; i < text.length && !executed; i += 1) {
      if (text.startsWith("\x1b[D", i)) {
        cursor = Math.max(0, cursor - 1);
        i += 2;
      } else if (text.startsWith("\x1b[C", i)) {
        cursor = Math.min(buffer.length, cursor + 1);
        i += 2;
      } else if (text[i] === "\b") {
        if (cursor > 0) {
          buffer = buffer.slice(0, cursor - 1) + buffer.slice(cursor);
          cursor -= 1;
        }
      } else if (text[i] === "\n") {
        executed = true;
      } else {
        buffer = buffer.slice(0, cursor) + (text[i] ?? "") + buffer.slice(cursor);
        cursor += 1;
      }
    }
    if (executed) {
      this.buffer = buffer;
      this.cursor = cursor;
      this.emit("preExec", { sessionId: this.requireSession().sessionId });
    } else {
      this.type(buffer, cursor);
    }
    return { buffer, cursor, executed };
  }

  /** Emits `keybinding`, as when an intercepted key is pressed. */
  press(action: string): void {
    this.emit("keybinding", { sessionId: this.requireSession().sessionId, action });
  }

  emitSettings(settings: Settings): void {
    this.settings = settings;
    this.emit("settings", { settings });
  }

  // ---- Inspection ---------------------------------------------------------------------------

  callsTo<Method extends keyof NativeRequests>(method: Method): Array<NativeRequests[Method]["params"]> {
    return this.calls
      .filter((call) => call.method === method)
      .map((call) => call.params as NativeRequests[Method]["params"]);
  }

  /** The `text` of every `shell.insert`, in order. */
  inserts(): string[] {
    return this.callsTo("shell.insert").map((params) => params.text);
  }

  lastIntercept(): NativeRequests["shell.setIntercept"]["params"] | undefined {
    return this.callsTo("shell.setIntercept").at(-1);
  }

  /** Every process run, as command lines. */
  processRuns(): string[] {
    return this.callsTo("process.run").map(commandLine);
  }

  clearCalls(): void {
    this.calls.length = 0;
  }

  // ---- Internals ----------------------------------------------------------------------------

  private requireSession(): ShellContext {
    if (!this.session) {
      throw new Error("Call startSession() first");
    }
    return this.session;
  }

  private resolvePath(path: string, sessionId: SessionId): string {
    const session = this.session?.sessionId === sessionId ? this.session : null;
    const home = session?.home ?? this.appInfo.home;
    let resolved = path === "~" || path.startsWith("~/") ? home + path.slice(1) : path;
    if (!resolved.startsWith("/")) {
      resolved = withSlash(session?.cwd ?? home) + resolved;
    }
    // Normalise `.` and `..` so `/a/b/../c` finds `/a/c`.
    const parts: string[] = [];
    for (const part of resolved.split("/")) {
      if (part === "..") {
        parts.pop();
      } else if (part !== "." && part !== "") {
        parts.push(part);
      }
    }
    return withSlash(`/${parts.join("/")}`);
  }

  private async answer(method: keyof NativeRequests, params: unknown): Promise<unknown> {
    switch (method) {
      case "app.ready":
        return { ...this.appInfo, settings: this.settings };
      case "fs.list": {
        const { path, sessionId } = params as NativeRequests["fs.list"]["params"];
        const entries = this.directories.get(this.resolvePath(path, sessionId));
        if (!entries) {
          throw new Error(`Cannot read directory ${path}`);
        }
        return { entries: [...entries] };
      }
      case "process.run": {
        const run = params as ProcessParams;
        const script = this.processes.find(({ matcher }) =>
          typeof matcher === "string"
            ? matcher === commandLine(run)
            : matcher instanceof RegExp
              ? matcher.test(commandLine(run))
              : matcher(run),
        );
        if (!script) {
          this.unmatchedProcesses.push(run);
          return { stdout: "", stderr: `${run.executable}: command not found`, exitCode: 127 };
        }
        const reply = typeof script.reply === "function" ? await script.reply(run) : script.reply;
        return { stdout: "", stderr: "", exitCode: 0, ...reply };
      }
      default:
        return null;
    }
  }
}
