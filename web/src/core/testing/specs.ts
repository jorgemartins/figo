import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { CoreOptions } from "../contract";

/** The compiled community specs (`node specs/build.mjs` in the repository root builds them). */
export const SPECS_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../../specs/dist");

/** `CoreOptions` that load specs from disk instead of the `figo://` scheme. */
export function diskSpecs(directory = SPECS_DIR): Pick<CoreOptions, "importSpec" | "loadIndex"> {
  return {
    importSpec: (name) => import(/* @vite-ignore */ pathToFileURL(path.join(directory, `${name}.js`)).href),
    loadIndex: async () => JSON.parse(await readFile(path.join(directory, "index.json"), "utf8")),
  };
}
