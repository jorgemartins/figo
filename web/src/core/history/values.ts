import type { ParseResult } from "../parser/parse";
import type { Annotation } from "../parser/state";
import { type AliasMap, expandAliases } from "../shell/aliases";
import { splitCommands } from "../shell/tokenize";
import type { Arg } from "../specs/types";

/** How many matching past commands are parsed to collect values. */
const MAX_PARSED = 200;

function flatten(annotations: readonly Annotation[]): Annotation[] {
  return annotations.flatMap((annotation) => (annotation.type === "composite" ? annotation.subtokens : [annotation]));
}

/**
 * The `history` template (engine doc §7): values the user gave the same spec argument in past
 * commands, most recent first. Each past command starting with the same word is parsed through
 * the spec, and every token consumed by `arg` is collected.
 */
export async function historyArgValues(
  entries: readonly string[],
  aliases: AliasMap,
  commandName: string,
  arg: Arg,
  parse: (tokens: string[]) => Promise<ParseResult>,
): Promise<string[]> {
  const values: string[] = [];
  let parsed = 0;
  for (const entry of entries) {
    for (const command of splitCommands(entry)) {
      const tokens = expandAliases(command, aliases).tokens.map((token) => token.text);
      if (tokens[0] !== commandName || tokens.length < 2) {
        continue;
      }
      parsed += 1;
      try {
        // An empty final token makes every real token a consumed one.
        const result = await parse([...tokens, ""]);
        for (const annotation of flatten(result.annotations)) {
          if (
            (annotation.type === "subcommand_arg" || annotation.type === "option_arg") &&
            annotation.arg?.source === arg &&
            annotation.text !== ""
          ) {
            values.push(annotation.text);
          }
        }
      } catch {
        // An unparsable past command contributes nothing.
      }
      if (parsed >= MAX_PARSED) {
        return [...new Set(values)];
      }
    }
  }
  return [...new Set(values)];
}
