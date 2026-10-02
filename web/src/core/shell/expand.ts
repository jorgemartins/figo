import { ensureTrailingSlash } from "../utils";

/** Expands a leading `~`, `$VAR` and `${VAR}` / `${VAR:-default}` the way path completion needs. */
export function shellExpand(path: string, home: string, env: Readonly<Record<string, string>>): string {
  let result = path;
  if (result === "~" || result.startsWith("~/")) {
    result = home + result.slice(1);
  }
  result = result.replace(/\$\{([A-Za-z0-9_]+)(?::-([^}]*))?\}/g, (match, key: string, fallback?: string) => {
    return env[key] ?? fallback ?? match;
  });
  return result.replace(/\$([A-Za-z0-9_]+)/g, (match, key: string) => env[key] ?? match);
}

/**
 * The directory a partially typed path points into, always absolute with a trailing slash:
 * `src/co` → `<cwd>/src/`, `~/Si` → `<home>/`, `co` → `<cwd>/`.
 */
export function directoryOfPath(
  searchTerm: string,
  cwd: string,
  home: string,
  env: Readonly<Record<string, string>>,
): string {
  const expanded = shellExpand(searchTerm, home, env);
  const dirname = expanded.slice(0, expanded.lastIndexOf("/") + 1);
  const base = ensureTrailingSlash(cwd || "/");
  if (dirname === "") {
    return base;
  }
  const absolute = dirname.startsWith("/") ? dirname : base + dirname;
  return absolute.replace(/^\/\/+/, "/");
}
