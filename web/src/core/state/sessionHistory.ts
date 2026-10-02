import type { NativeBridge, SessionId, Settings, ShellContext } from "../../bridge/contract";
import type { GeneratorContext } from "../generators/context";
import { History, readShellHistory } from "../history/history";
import { historyArgValues } from "../history/values";
import type { ParseResult } from "../parser/parse";
import { SETTING, booleanSetting, stringSetting } from "../settings";
import type { AliasMap } from "../shell/aliases";

export interface SessionHistoryDeps {
  bridge: NativeBridge;
  session: () => { id: SessionId; context: ShellContext | null } | null;
  settings: () => Settings;
  aliases: () => AliasMap;
  /** Parses a past command without running anything. */
  parse: (tokens: string[]) => Promise<ParseResult>;
}

/** Shell history as seen from the focused session: which source to read and how to read it. */
export class SessionHistory {
  private readonly history = new History();

  constructor(private readonly deps: SessionHistoryDeps) {}

  get version(): number {
    return this.history.version;
  }

  add(command: string): void {
    this.history.add(command);
  }

  /** The current session's entries, most recent first (empty until loaded). */
  entries(): string[] {
    return this.history.entries(this.source());
  }

  /** Reads the session shell's history once; resolves when it is available. */
  async load(): Promise<void> {
    const session = this.deps.session();
    if (session === null || booleanSetting(this.deps.settings(), SETTING.historyDisableLoading)) {
      return;
    }
    const shell = session.context?.shell ?? "";
    const shellPath = session.context?.shellPath ?? shell;
    const customCommand = stringSetting(this.deps.settings(), SETTING.historyCustomCommand);
    await this.history.ensureLoaded(this.source(), () =>
      readShellHistory(
        async (executable, args) => {
          const result = await this.deps.bridge.call("process.run", {
            sessionId: session.id,
            executable,
            args,
            timeoutMs: 5_000,
          });
          return result.stdout.replace(/\r\n/g, "\n");
        },
        shell,
        shellPath,
        customCommand,
      ),
    );
  }

  /** The `history` template: values given to the current argument in past commands. */
  async values(context: GeneratorContext): Promise<Fig.TemplateSuggestion[]> {
    const commandName = context.tokens[0];
    if (!context.currentArg || commandName === undefined) {
      return [];
    }
    await this.load();
    const values = await historyArgValues(
      this.entries(),
      this.deps.aliases(),
      commandName,
      context.currentArg.source,
      this.deps.parse,
    );
    return values.map((value) => ({ name: value, type: "arg", context: { templateType: "history" } }));
  }

  private source(): string {
    const customCommand = stringSetting(this.deps.settings(), SETTING.historyCustomCommand);
    return customCommand ? `custom:${customCommand}` : (this.deps.session()?.context?.shell ?? "");
  }
}
