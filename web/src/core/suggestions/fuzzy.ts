/**
 * Fuzzy matching with the scoring model of the fuzzysort version upstream ships (engine doc §6.7):
 * every query character must appear in order; a second pass prefers placing characters at word
 * beginnings or right after the previous match. The score is 0 for an exact match and more
 * negative for worse ones (−index for every non-consecutive match, ×1000 when no "strict"
 * placement exists, minus the length difference).
 */

export interface FuzzyMatch {
  score: number;
  /** Matched positions in the target, ascending. */
  indexes: number[];
}

/**
 * Steps the strict pass may take. Its backtracking tries every placement of the query over the
 * word beginnings, which is exponential on long names with many of them; past this budget the
 * match counts as one without a strict placement. Real names need a few dozen steps.
 */
const MAX_STRICT_STEPS = 2_000;

function isUpper(code: number): boolean {
  return code >= 65 && code <= 90;
}

function isAlphanumeric(code: number): boolean {
  return isUpper(code) || (code >= 97 && code <= 122) || (code >= 48 && code <= 57);
}

/** For each index, the next index (after it) where a word begins, or the length. */
function nextBeginnings(target: string): number[] {
  const beginnings: number[] = [];
  let wasUpper = false;
  let wasAlphanumeric = false;
  for (let i = 0; i < target.length; i += 1) {
    const code = target.charCodeAt(i);
    const upper = isUpper(code);
    const alphanumeric = isAlphanumeric(code);
    if ((upper && !wasUpper) || !wasAlphanumeric || !alphanumeric) {
      beginnings.push(i);
    }
    wasUpper = upper;
    wasAlphanumeric = alphanumeric;
  }
  const next: number[] = [];
  let b = 0;
  for (let i = 0; i < target.length; i += 1) {
    while (b < beginnings.length && (beginnings[b] ?? 0) <= i) {
      b += 1;
    }
    next.push(beginnings[b] ?? target.length);
  }
  return next;
}

export function fuzzyMatch(query: string, target: string): FuzzyMatch | null {
  if (query === "" || target === "") {
    return null;
  }
  const q = query.toLowerCase();
  const t = target.toLowerCase();

  const simple: number[] = [];
  let ti = 0;
  for (let qi = 0; qi < q.length; qi += 1) {
    while (ti < t.length && t.charCodeAt(ti) !== q.charCodeAt(qi)) {
      ti += 1;
    }
    if (ti >= t.length) {
      return null;
    }
    simple.push(ti);
    ti += 1;
  }

  const next = nextBeginnings(target);
  const strict: number[] = [];
  let strictOk = false;
  const firstSimple = simple[0] ?? 0;
  ti = firstSimple === 0 ? 0 : (next[firstSimple - 1] ?? t.length);
  let qi = 0;
  let steps = 0;
  if (ti !== t.length) {
    for (;;) {
      steps += 1;
      if (steps > MAX_STRICT_STEPS) {
        break;
      }
      if (ti >= t.length) {
        // Could not place this character well: move the previous one to its next beginning.
        if (qi <= 0) {
          break;
        }
        qi -= 1;
        const previous = strict.pop() ?? 0;
        ti = next[previous] ?? t.length;
        continue;
      }
      if (q.charCodeAt(qi) === t.charCodeAt(ti)) {
        strict.push(ti);
        qi += 1;
        if (qi === q.length) {
          strictOk = true;
          break;
        }
        ti += 1;
      } else {
        ti = next[ti] ?? t.length;
      }
    }
  }

  const indexes = strictOk ? strict : simple;
  let score = 0;
  let previous = -1;
  for (const index of indexes) {
    if (previous !== index - 1) {
      score -= index;
    }
    previous = index;
  }
  if (!strictOk) {
    score *= 1000;
  }
  score -= t.length - q.length;
  return { score, indexes };
}

/** Collapses ascending indexes into [start, end) ranges. */
export function indexesToRanges(indexes: readonly number[]): Array<[number, number]> {
  const ranges: Array<[number, number]> = [];
  for (const index of indexes) {
    const last = ranges[ranges.length - 1];
    if (last !== undefined && last[1] === index) {
      last[1] = index + 1;
    } else {
      ranges.push([index, index + 1]);
    }
  }
  return ranges;
}
