import type { ArgumentHint, Suggestion } from "../contract";
import type { RankedItem } from "./types";

/** `fig://path/<absolute path>`, each segment percent-encoded so spaces and `#` survive in CSS URLs. */
export function pathIcon(absolutePath: string): string {
  return `fig://path${absolutePath.split("/").map(encodeURIComponent).join("/")}`;
}

/**
 * Converts a list entry for the UI. Files and folders get a `fig://path/` icon for the directory
 * being listed, since only the core knows which directory that is.
 */
export function presentItem(item: RankedItem, listedDirectory: string | null): Suggestion {
  const suggestion: Suggestion = { type: item.type ?? "arg", names: item.names, match: item.match };
  if (item.displayName !== undefined) {
    suggestion.displayName = item.displayName;
  }
  if (item.description !== undefined && item.description !== "") {
    suggestion.description = item.description;
  }
  if (item.icon !== undefined) {
    suggestion.icon = item.icon;
  } else if ((item.type === "file" || item.type === "folder") && listedDirectory !== null) {
    suggestion.icon = pathIcon(`${listedDirectory}${item.names[0] ?? ""}`);
  }
  const hints: ArgumentHint[] = (item.args ?? [])
    .filter((arg) => typeof arg.name === "string" && arg.name !== "")
    .map((arg) => ({
      name: arg.name as string,
      isOptional: Boolean(arg.isOptional),
      isVariadic: Boolean(arg.isVariadic),
    }));
  if (hints.length > 0) {
    suggestion.args = hints;
  }
  if (item.isDangerous) {
    suggestion.isDangerous = true;
  }
  return suggestion;
}
