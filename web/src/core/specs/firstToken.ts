import { convertSubcommand } from "./convert";
import type { Subcommand } from "./types";

/** How each shell lists the commands it can run, through a login shell (engine doc §3.2). */
const LIST_COMMANDS: Record<string, string> = {
  bash: "compgen -c",
  zsh: "for key in ${(k)commands}; do echo $key; done && alias +r",
  fish: 'complete -C ""',
};

const listCommands: Fig.Generator = {
  cache: { strategy: "stale-while-revalidate", ttl: 10_000 },
  custom: async (_tokens, executeCommand, context) => {
    const shell = context.currentProcess.slice(context.currentProcess.lastIndexOf("/") + 1);
    const script = LIST_COMMANDS[shell];
    if (script === undefined) {
      return [];
    }
    const { stdout } = await executeCommand({ command: shell, args: ["-lic", script] });
    const seen = new Set<string>();
    const suggestions: Fig.Suggestion[] = [];
    for (const line of stdout.split("\n")) {
      const tab = line.indexOf("\t");
      const name = (tab === -1 ? line : line.slice(0, tab)).trim();
      if (name === "" || seen.has(name)) {
        continue;
      }
      seen.add(name);
      const description = tab === -1 ? undefined : line.slice(tab + 1).trim() || undefined;
      suggestions.push({ name, description, type: "subcommand" });
    }
    return suggestions;
  },
};

const withCommands = convertSubcommand({ name: "firstTokenSpec", args: { name: "command", generators: listCommands } });
const withoutCommands = convertSubcommand({ name: "firstTokenSpec" });

/** The spec for the first word; it only suggests commands with `autocomplete.firstTokenCompletion`. */
export function firstTokenSpec(listCommandNames: boolean): Subcommand {
  return listCommandNames ? withCommands : withoutCommands;
}
