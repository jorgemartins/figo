/**
 * The popup's four visibility states (UI doc §5, engine doc §8).
 *
 * - visible
 * - hiddenUntilKeypress: initial; after a reset, Up on the first row, a paste, a backspace into
 *   the previous token, or an insertion that led nowhere new. The next parse shows it.
 * - hiddenUntilShown: Esc. Stays hidden for the rest of the line, until a reset or a show action.
 * - hiddenByInsertion: right after a full insertion, until the shell echoes it.
 */
export type Visibility = "visible" | "hiddenUntilKeypress" | "hiddenUntilShown" | "hiddenByInsertion";

export interface ParseOutcome {
  /** The parse moved to a different spec argument (or spec node). */
  hasNewArg: boolean;
  /** The generator of the last inserted suggestion ran again (a folder was entered). */
  insertionRetriggered: boolean;
  backspacedIntoPreviousToken: boolean;
  /** The line changed by more than one character, not through our insertion. */
  largeChange: boolean;
  justInserted: boolean;
  /** `autocomplete.onlyShowOnTab`. */
  onlyShowOnTab: boolean;
}

export function visibilityAfterParse(current: Visibility, outcome: ParseOutcome): Visibility {
  let next = current;
  if (current === "hiddenUntilKeypress") {
    next = "visible";
  } else if (current === "hiddenByInsertion") {
    next = outcome.hasNewArg || outcome.insertionRetriggered ? "visible" : "hiddenUntilKeypress";
  }
  if (outcome.onlyShowOnTab) {
    next = outcome.hasNewArg ? "hiddenUntilShown" : current;
  }
  if (outcome.backspacedIntoPreviousToken) {
    next = "hiddenUntilKeypress";
  }
  if (outcome.largeChange && !outcome.justInserted) {
    next = "hiddenUntilKeypress";
  }
  return next;
}
