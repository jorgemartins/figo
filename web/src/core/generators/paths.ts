import type { NativeBridge, SessionId } from "../../bridge/contract";
import { directoryOfPath } from "../shell/expand";

/**
 * The `filepaths` / `folders` templates. A fresh generator object is made for every argument that
 * uses them, so a spec's `filterTemplateSuggestions` cannot leak into another spec's arguments.
 */
export interface PathsGeneratorOptions {
  foldersOnly: boolean;
  filterTemplateSuggestions?: Fig.Generator["filterTemplateSuggestions"];
}

/** Path generators re-run when the directory part of the token changes, not on every key. */
function pathTrigger(newToken: string, oldToken: string): boolean {
  const newSlash = newToken.lastIndexOf("/");
  const oldSlash = oldToken.lastIndexOf("/");
  if (newSlash !== oldSlash) {
    return true;
  }
  if (newSlash === -1) {
    return false;
  }
  return newToken.slice(0, newSlash) !== oldToken.slice(0, oldSlash);
}

function pathQueryTerm(token: string): string {
  return token.slice(token.lastIndexOf("/") + 1);
}

/** Directory entries in the order Fig shows them: names, then dotfiles, then `../`. */
function sortDirectoryNames(names: readonly string[]): string[] {
  const shown = names.filter((name) => name !== "" && name.toLowerCase() !== ".ds_store");
  const byName = (a: string, b: string) => a.localeCompare(b);
  return [
    ...shown.filter((name) => !name.startsWith(".")).sort(byName),
    ...shown.filter((name) => name.startsWith(".")).sort(byName),
    "../",
  ];
}

export function pathsGenerator(options: PathsGeneratorOptions): Fig.Generator {
  return {
    trigger: pathTrigger,
    getQueryTerm: pathQueryTerm,
    filterTemplateSuggestions: options.filterTemplateSuggestions,
    custom: async (_tokens, executeCommand, context) => {
      const env = context.environmentVariables ?? {};
      const directory = directoryOfPath(context.searchTerm, context.currentWorkingDirectory, env.HOME ?? "~", env);
      const { stdout } = await executeCommand({ command: "ls", args: ["-1ApL"], cwd: directory });
      const suggestions: Fig.TemplateSuggestion[] = [];
      for (const name of sortDirectoryNames(stdout.split("\n"))) {
        const isFolder = name.endsWith("/");
        if (options.foldersOnly && !isFolder) {
          continue;
        }
        suggestions.push({
          type: isFolder ? "folder" : "file",
          name,
          insertValue: name,
          isDangerous: context.isDangerous,
          context: { templateType: isFolder ? "folders" : "filepaths" },
        });
      }
      return suggestions;
    },
  };
}

/**
 * Answers the `ls -1ApL` that path generators (Figo's and the copies bundled into specs such as
 * `cd`) run, using the bridge's directory listing instead of a subprocess: folders get a trailing
 * slash, symlinks are described by their target. Rejects when the directory cannot be read, so a
 * mistyped path lists nothing rather than some other directory.
 */
export async function listLikeLs(bridge: NativeBridge, sessionId: SessionId, path: string): Promise<string> {
  const { entries } = await bridge.call("fs.list", { sessionId, path });
  return entries.map((entry) => (entry.kind === "directory" ? `${entry.name}/` : entry.name)).join("\n");
}
