export function makeArray<T>(value: T | readonly T[] | undefined | null): T[] {
  if (value === undefined || value === null) {
    return [];
  }
  return Array.isArray(value) ? [...(value as readonly T[])] : [value as T];
}

export function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export function ensureTrailingSlash(path: string): string {
  return path.endsWith("/") ? path : `${path}/`;
}

export function longestCommonPrefix(strings: readonly string[]): string {
  const [first, ...rest] = strings;
  if (first === undefined) {
    return "";
  }
  let length = first.length;
  for (const other of rest) {
    let i = 0;
    while (i < length && i < other.length && first.charCodeAt(i) === other.charCodeAt(i)) {
      i += 1;
    }
    length = i;
  }
  return first.slice(0, length);
}

/**
 * C0 controls, DEL and C1 controls. Typed into a terminal they are editing keys (`^U` erases the
 * line, `\r` runs it), so text from file names, generators or history must never contain them.
 */
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f-\u009f]/;

export function hasControlCharacters(text: string): boolean {
  return CONTROL_CHARACTERS.test(text);
}

/** Number of user-perceived edit positions: a terminal backspace or arrow moves over a code point, not a UTF-16 unit. */
export function codePointLength(text: string): number {
  let count = 0;
  for (const _ of text) {
    count += 1;
  }
  return count;
}

export class TimeoutError extends Error {
  constructor(ms: number) {
    super(`Timed out after ${ms} ms`);
    this.name = "TimeoutError";
  }
}

export function withTimeout<T>(ms: number, promise: Promise<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new TimeoutError(ms)), ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

/** Shallow comparison of the listed fields, comparing arrays element by element. */
export function fieldsEqual<T>(a: T, b: T, fields: readonly (keyof T)[]): boolean {
  return fields.every((field) => shallowValueEqual(a[field], b[field]));
}

function shallowValueEqual(a: unknown, b: unknown): boolean {
  if (a === b) {
    return true;
  }
  if (Array.isArray(a) && Array.isArray(b)) {
    return a.length === b.length && a.every((item, i) => shallowValueEqual(item, b[i]));
  }
  if (isObject(a) && isObject(b)) {
    const keysA = Object.keys(a);
    const keysB = Object.keys(b);
    return keysA.length === keysB.length && keysA.every((key) => a[key] === b[key]);
  }
  return false;
}
