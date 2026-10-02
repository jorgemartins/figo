// Compiles the community completion specs into dist/, one ES module per spec plus an index.
//
// The specs are fetched at the commit pinned in package.json, so a build is reproducible and
// updating them is a one-line change.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const root = path.dirname(fileURLToPath(import.meta.url));
const { figo } = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
const checkout = path.join(root, ".cache", "autocomplete");
const outdir = path.join(root, "dist");

function git(...args) {
  return execFileSync("git", ["-C", checkout, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

function fetchSource() {
  if (!existsSync(path.join(checkout, ".git"))) {
    mkdirSync(checkout, { recursive: true });
    git("init", "--quiet");
    git("remote", "add", "origin", figo.source);
  }
  try {
    if (git("rev-parse", "--verify", "--quiet", "HEAD^{commit}") === figo.commit) return;
  } catch {
    // Nothing checked out yet.
  }
  console.log(`Fetching ${figo.source} at ${figo.commit.slice(0, 7)}`);
  git("fetch", "--quiet", "--depth", "1", "origin", figo.commit);
  git("checkout", "--quiet", "--detach", "FETCH_HEAD");
}

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const file = path.join(dir, name);
    return statSync(file).isDirectory() ? walk(file) : [file];
  });
}

fetchSource();

const src = path.join(checkout, "src");
const files = walk(src).filter((file) => file.endsWith(".ts") && !file.endsWith(".d.ts"));
const names = files.map((file) => path.relative(src, file).replace(/\.ts$/, ""));

// A folder with an index.ts holds one spec split by CLI version ("diff-versioned").
const diffVersioned = names.filter((name) => path.basename(name) === "index").map((name) => path.dirname(name)).sort();
const completions = names
  .filter((name) => path.basename(name) !== "index")
  .concat(diffVersioned)
  .sort();

rmSync(outdir, { recursive: true, force: true });
const started = Date.now();
const result = await build({
  entryPoints: files,
  outdir,
  outbase: src,
  bundle: true,
  format: "esm",
  minify: true,
  target: "safari17",
  logLevel: "warning",
});

writeFileSync(
  path.join(outdir, "index.json"),
  JSON.stringify({ commit: figo.commit, completions, diffVersionedCompletions: diffVersioned }),
);

console.log(
  `Built ${completions.length} specs (${files.length} modules) in ${Date.now() - started}ms` +
    (result.warnings.length ? ` with ${result.warnings.length} warnings` : ""),
);
