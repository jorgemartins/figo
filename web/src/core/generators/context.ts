import type { Annotation, ParsedArg } from "../parser/state";
import type { ExecuteCommand } from "../specs/types";
import type { GeneratorCache } from "./cache";

/** What a generator runs against: one parse of the command line. */
export interface GeneratorContext {
  /** Token texts from the start of the command the spec belongs to; the last is the search term. */
  tokens: string[];
  searchTerm: string;
  cwd: string;
  /** The shell's environment, with HOME filled in. */
  env: Record<string, string>;
  /** `zsh`, `bash` or `fish`. */
  shell: string;
  isDangerous: boolean;
  annotations: Annotation[];
  currentArg: ParsedArg | null;
}

export interface GeneratorServices {
  /** An executeCommand bound to the session; `cwd` is the default directory, if any. */
  executeCommand(cwd?: string, timeoutMs?: number): ExecuteCommand;
  cache: GeneratorCache;
  /** `autocomplete.scriptTimeout`. */
  scriptTimeout: number;
  /** `beta.autocomplete.auto-cache`: generators without a cache get a short stale-while-revalidate one. */
  autoCache: boolean;
  /** Values seen for the current argument in shell history (the `history` template). */
  historyValues(context: GeneratorContext): Promise<Fig.TemplateSuggestion[]>;
}

/** A generator's raw output item, before it becomes a list entry. */
export type GeneratedSuggestion = Fig.Suggestion & { context?: Fig.TemplateSuggestionContext };

export function figContext(context: GeneratorContext): Fig.GeneratorContext {
  return {
    currentWorkingDirectory: context.cwd,
    currentProcess: context.shell,
    sshPrefix: "",
    environmentVariables: context.env,
    searchTerm: context.searchTerm,
    isDangerous: context.isDangerous,
  };
}
