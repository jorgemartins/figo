import type { SuggestionType } from "../contract";
import type { Arg } from "../specs/types";

/** A list entry inside the core, before it is presented to the UI. */
export interface Item {
  /** Undefined for untyped `additionalSuggestions`; presented as `arg`. */
  type: SuggestionType | undefined;
  names: string[];
  displayName?: string;
  description?: string;
  icon?: string;
  insertValue?: string;
  priority?: number;
  hidden?: boolean;
  isDangerous?: boolean;
  /** The arguments of a subcommand or option. */
  args?: Arg[];
  shouldAddSpace?: boolean;
  separatorToAdd?: string;
  /** The generator that produced it: its `getQueryTerm` applies, and insertion visibility uses it. */
  generator?: Fig.Generator;
  /** Overrides the query term (option chains show argument values unfiltered). */
  queryTerm?: (searchTerm: string) => string;
  templateType?: string;
  /** For auto-execute entries: the type of what they stand for. */
  originalType?: SuggestionType;
  /** Effective priority after recency, set while ranking. */
  rank?: number;
}

export interface MatchInfo {
  nameIndex: number;
  ranges: Array<[number, number]>;
}

/** An entry as shown, with where the query matched. */
export interface RankedItem extends Item {
  match: MatchInfo;
}
