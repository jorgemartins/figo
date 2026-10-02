import type { SpecLocation } from "./types";

function splitPath(path: string): [dirname: string, basename: string] {
  const at = path.lastIndexOf("/");
  return [path.slice(0, at + 1), path.slice(at + 1)];
}

/**
 * Where the spec for a command word lives.
 *
 * `isScript` is undefined for the first word of a command line, false for an `isCommand` argument
 * (`sudo <cmd>`) and true for an `isScript` argument. Paths name a LOCAL spec next to the script,
 * which Figo cannot read; loading those fails and the parser falls back to file completion.
 */
export function specLocationFor(name: string, cwd: string, isScript?: boolean): SpecLocation {
  const [dirname, basename] = splitPath(name);
  if (!isScript) {
    if (isScript === undefined) {
      if (name === "bin/console" || name.endsWith("/bin/console")) {
        return { type: "global", name: "php/bin-console" };
      }
      if (!name.includes("/")) {
        return { type: "global", name };
      }
    } else if (!["/", "./", "~/"].some((prefix) => dirname.startsWith(prefix))) {
      return { type: "global", name };
    }
  }
  if (dirname.startsWith("/") || dirname.startsWith("~/")) {
    return { type: "local", name: basename, path: dirname };
  }
  const relative = dirname.startsWith("./") ? dirname.slice(2) : dirname;
  return { type: "local", name: basename, path: `${cwd}/${relative}` };
}
