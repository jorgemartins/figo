import type { RankedItem } from "../suggestions/types";
import { fieldsEqual } from "../utils";

/**
 * Where the selection lands when the list is rebuilt (UI doc §3.1): the first row, unless the
 * user moved it and the entry they picked is still there.
 */
export function reselect(
  previous: readonly RankedItem[],
  previousIndex: number,
  userMoved: boolean,
  list: readonly RankedItem[],
): { index: number; userMoved: boolean } {
  const selected = previous[previousIndex];
  if (userMoved && selected !== undefined) {
    const index = list.findIndex((item) =>
      fieldsEqual(item, selected, ["names", "type", "insertValue", "description"]),
    );
    if (index !== -1) {
      return { index, userMoved: true };
    }
  }
  return { index: 0, userMoved: false };
}

export type NavigateResult = { kind: "move"; index: number } | { kind: "beforeFirst" };

/** Moving the selection by `delta`; stepping up from the first row is reported, not clamped. */
export function navigateTo(index: number, delta: number, count: number, wrap: boolean): NavigateResult {
  const next = index + delta;
  if (wrap) {
    return { kind: "move", index: (next + count) % count };
  }
  if (next < 0 && delta < 0) {
    return { kind: "beforeFirst" };
  }
  return { kind: "move", index: Math.max(0, Math.min(next, count - 1)) };
}
