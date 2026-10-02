/// <reference types="@withfig/autocomplete-types" />

/**
 * The normalised form of a completion spec that the parser walks. Spec modules are converted once
 * when loaded; names become arrays and children are keyed by every name they answer to. Maps are
 * used instead of plain objects so a token such as `constructor` can never hit a prototype key.
 */

export type SpecLocation = { type: "global"; name: string } | { type: "local"; name: string; path?: string };

export type ExecuteCommand = Fig.ExecuteCommandFunction;

export type LoadSpec =
  | SpecLocation[]
  | Subcommand
  | ((token: string, executeCommand: ExecuteCommand) => Promise<SpecLocation[] | Subcommand>);

export type ParserDirectives = NonNullable<Fig.Subcommand["parserDirectives"]>;

export interface Arg extends Omit<Fig.Arg, "template" | "generators" | "loadSpec"> {
  generators: Fig.Generator[];
  loadSpec?: LoadSpec;
}

export interface Option extends Omit<Fig.Option, "name" | "args"> {
  name: string[];
  args: Arg[];
}

export interface Subcommand extends Omit<
  Fig.Subcommand,
  "name" | "subcommands" | "options" | "args" | "loadSpec" | "generateSpec"
> {
  name: string[];
  subcommands: ReadonlyMap<string, Subcommand>;
  options: ReadonlyMap<string, Option>;
  persistentOptions: ReadonlyMap<string, Option>;
  args: Arg[];
  loadSpec?: LoadSpec;
  generateSpec?: (tokens: string[], executeCommand: ExecuteCommand) => Promise<unknown>;
}

export function serializeLocation(location: SpecLocation): string {
  return location.type === "global" ? `global:${location.name}` : `local:${location.path ?? ""}:${location.name}`;
}
