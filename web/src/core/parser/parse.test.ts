/**
 * The parser conformance table (engine doc §4.9) and upstream's parser test vectors, run against
 * a test spec of the same shape as upstream's mock.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { getCommand } from "../shell/tokenize";
import { convertSubcommand } from "../specs/convert";
import { firstTokenSpec } from "../specs/firstToken";
import type { Arg, SpecLocation, Subcommand } from "../specs/types";
import { ParseCache, type ParseContext, type ParseResult, SuggestionFlag, parseArguments } from "./parse";

const options: Fig.Option[] = [
  { name: ["-m", "--man"], args: {} },
  { name: ["-o", "--opt"], args: { isOptional: true } },
  { name: "-v", args: { isVariadic: true } },
  { name: "--multiple", args: [{}, {}] },
  { name: ["-n", "--none"] },
  { name: "-pnfm", args: {} },
  { name: "--req-eq", requiresEquals: true, args: {} },
  { name: "--req-sep", requiresSeparator: ":", args: {} },
  { name: "-pnfo", args: { isOptional: true } },
  { name: "-pnfn" },
];

const shared: Fig.Subcommand[] = [
  { name: "loadSpec", loadSpec: "loadSpecName" },
  { name: "module", args: { isModule: "python/" } },
  { name: "normal", args: { isOptional: true } },
  { name: "sudo", args: { isCommand: true } },
];

const sub = (spec: Partial<Fig.Subcommand> & { name: string }): Fig.Subcommand => ({
  options,
  subcommands: shared,
  ...spec,
});

const cmdSpec: Fig.Subcommand = sub({
  name: "cmd",
  subcommands: [
    sub({ name: "man", args: [{ name: "arg1" }, { name: "arg2" }] }),
    sub({
      name: "oas",
      parserDirectives: { optionArgSeparators: ["=", ":"] },
      args: [{ name: "arg1" }, { name: "arg2" }],
    }),
    sub({
      name: "opt",
      args: [
        { name: "arg1", isOptional: true },
        { name: "arg2", isOptional: true },
      ],
    }),
    sub({ name: "var", args: [{ name: "argv", isVariadic: true }] }),
    sub({ name: "none" }),
    sub({ name: "pnf", parserDirectives: { flagsArePosixNoncompliant: true } }),
    sub({ name: "ompa", parserDirectives: { optionsMustPrecedeArguments: true }, args: [{ name: "argv" }] }),
    ...shared,
  ],
});

const specToLoad = convertSubcommand({ name: "specToLoad", args: { name: "loaded" } });

let cmd: Subcommand;
let loadSpec: ReturnType<typeof vi.fn<(location: SpecLocation) => Promise<Subcommand>>>;

function context(): ParseContext {
  return {
    cwd: "/path/to/cwd",
    loadSpec,
    executeCommand: () => Promise.reject(new Error("no commands in parser tests")),
    firstTokenSpec: firstTokenSpec(false),
    cache: new ParseCache(),
  };
}

async function parse(buffer: string): Promise<ParseResult> {
  const command = getCommand(buffer);
  if (command === null) {
    throw new Error(`Nothing to parse in ${buffer}`);
  }
  return parseArguments(
    command.tokens.map((token) => token.text),
    context(),
  );
}

const child = (name: string): Subcommand => {
  const found = cmd.subcommands.get(name);
  if (!found) {
    throw new Error(`No subcommand ${name}`);
  }
  return found;
};
const arg = (node: Subcommand, index: number): Arg | undefined => node.args[index];
const optionArg = (node: Subcommand, option: string): Arg | undefined =>
  (node.options.get(option) ?? node.persistentOptions.get(option))?.args[0];

const { Any, Args } = SuggestionFlag;
const ArgsAndOptions = SuggestionFlag.Args | SuggestionFlag.Options;

beforeEach(() => {
  cmd = convertSubcommand(cmdSpec);
  loadSpec = vi.fn(async (location: SpecLocation) => {
    if (location.name === "cmd") {
      return cmd;
    }
    if (location.type === "global" && (location.name === "loadSpecName" || location.name === "python/moduleName")) {
      return specToLoad;
    }
    throw new Error(`missing ${location.name}`);
  });
});

type Row = [buffer: string, flags: number, expected: () => Arg | null | undefined, searchTerm: string];

async function check([buffer, flags, expected, searchTerm]: Row) {
  const result = await parse(buffer);
  expect({ flags: result.flags, searchTerm: result.searchTerm }).toEqual({ flags, searchTerm });
  // Identity, not shape: several of the test spec's arguments look alike.
  expect(result.currentArg?.source ?? null).toBe(expected() ?? null);
  expect(result.fallback).toBe(false);
}

describe("conformance table (engine doc §4.9)", () => {
  const man = () => child("man");
  const oas = () => child("oas");
  const ompa = () => child("ompa");
  it.each<Row>([
    ["cmd man ", Any, () => arg(man(), 0), ""],
    ["cmd man arg1 arg2 ", ArgsAndOptions, () => null, ""],
    ["cmd -o ", Any, () => optionArg(cmd, "-o"), ""],
    ["cmd --opt ", Any, () => optionArg(cmd, "--opt"), ""],
    ["cmd man --", Any, () => arg(man(), 0), "--"],
    ["cmd man -- ", Args, () => arg(man(), 0), ""],
    ["cmd man -- -o ", Args, () => arg(man(), 1), ""],
    ["cmd man --opt=arg ", Any, () => arg(man(), 0), ""],
    ["cmd man --none=arg ", ArgsAndOptions, () => arg(man(), 1), ""],
    ["cmd man --opt=arg", Args, () => optionArg(man(), "--opt"), "arg"],
    ["cmd man --none=arg", Any, () => arg(man(), 0), "--none=arg"],
    ["cmd man --req-eq ", Any, () => arg(man(), 0), ""],
    ["cmd man --req-eq=", Args, () => optionArg(man(), "--req-eq"), ""],
    ["cmd oas --req-sep:", Args, () => optionArg(oas(), "--req-sep"), ""],
    ["cmd man -oarg", Args, () => optionArg(man(), "-o"), "arg"],
    ["cmd man -marg", Args, () => optionArg(man(), "-m"), "arg"],
    ["cmd man -o=arg", Args, () => optionArg(man(), "-o"), "=arg"],
    ["cmd man -omarg", Args, () => optionArg(man(), "-m"), "arg"],
    ["cmd man -moarg", Args, () => optionArg(man(), "-m"), "oarg"],
    ["cmd man -nb", Any, () => arg(man(), 0), "-nb"],
    ["cmd -m arg ", Any, () => null, ""],
    ["cmd -v arg ", ArgsAndOptions, () => optionArg(cmd, "-v"), ""],
    ["cmd ompa argument ", Args, () => null, ""],
    ["cmd ompa -m argument ", Any, () => arg(ompa(), 0), ""],
  ])("%j", (...row) => check(row));

  it("cmd notASubcommand : Figo falls back to file completion instead of rejecting", async () => {
    const result = await parse("cmd notASubcommand ");
    expect(result.fallback).toBe(true);
    expect(result.flags).toBe(Args);
    expect(result.currentArg?.generators).toHaveLength(1);
    expect(result.currentArg?.generators[0]?.getQueryTerm).toBeTypeOf("function");
  });

  it("./test (single token) loads dotslash", async () => {
    await parse("./test");
    expect(loadSpec).toHaveBeenLastCalledWith({ type: "global", name: "dotslash" });
  });

  it("./dir/test  loads a LOCAL spec next to the script", async () => {
    const result = await parse("./dir/test ");
    expect(loadSpec).toHaveBeenLastCalledWith({ type: "local", name: "test", path: "/path/to/cwd/dir/" });
    expect(result.fallback).toBe(true);
  });
});

describe("upstream parser vectors", () => {
  const man = () => child("man");
  const pnf = () => child("pnf");
  const oas = () => child("oas");
  const vrd = () => child("var");
  const opt = () => child("opt");
  const ompa = () => child("ompa");
  it.each<Row>([
    ["cmd pnf -pnfo ", Any, () => optionArg(pnf(), "-pnfo"), ""],
    ["cmd man normal", Any, () => arg(man(), 0), "normal"],
    ["cmd man a", Any, () => arg(man(), 0), "a"],
    ["cmd man -o", Any, () => optionArg(man(), "-o"), "-o"],
    ["cmd man --man=arg ", Any, () => arg(man(), 0), ""],
    ["cmd man --man=arg", Args, () => optionArg(man(), "--man"), "arg"],
    ["cmd pnf -pnfo=arg ", Any, () => null, ""],
    ["cmd pnf -pnfm=arg ", Any, () => null, ""],
    ["cmd pnf -pnfo=arg", Args, () => optionArg(pnf(), "-pnfo"), "arg"],
    ["cmd pnf -pnfm=arg", Args, () => optionArg(pnf(), "-pnfm"), "arg"],
    ["cmd man --req-eq=arg ", Any, () => arg(man(), 0), ""],
    ["cmd man --req-sep=arg ", Any, () => arg(man(), 0), ""],
    ["cmd man --req-sep=", Args, () => optionArg(man(), "--req-sep"), ""],
    ["cmd oas --req-sep:arg ", Any, () => arg(oas(), 0), ""],
    ["cmd oas --req-sep=arg ", Any, () => arg(oas(), 0), ""],
    ["cmd oas --req-sep=", Args, () => optionArg(oas(), "--req-sep"), ""],
    ["cmd oas --req-sep ", Any, () => arg(oas(), 0), ""],
    ["cmd man -oarg ", Any, () => arg(man(), 0), ""],
    ["cmd man -m=arg", Args, () => optionArg(man(), "-m"), "=arg"],
    ["cmd man -marg ", Any, () => arg(man(), 0), ""],
    ["cmd man -on", Any, () => null, "-on"],
    ["cmd man --opt", Any, () => arg(man(), 0), "--opt"],
    ["cmd man --opt=", Args, () => optionArg(man(), "-o"), ""],
    ["cmd -o arg ", Any, () => null, ""],
    ["cmd --man arg ", Any, () => null, ""],
    ["cmd --opt arg ", Any, () => null, ""],
    ["cmd -n ", Any, () => null, ""],
    ["cmd ompa -o ", Any, () => arg(ompa(), 0), ""],
    ["cmd ompa -m ", Args, () => optionArg(ompa(), "-m"), ""],
    ["cmd man -m ", Args, () => optionArg(man(), "-m"), ""],
    ["cmd man -o ", Any, () => arg(man(), 0), ""],
    ["cmd man -v ", Args, () => optionArg(man(), "-v"), ""],
    ["cmd man -n ", Any, () => arg(man(), 0), ""],
    ["cmd var -m ", Args, () => optionArg(vrd(), "-m"), ""],
    ["cmd var -o ", Any, () => arg(vrd(), 0), ""],
    ["cmd var -n ", Any, () => arg(vrd(), 0), ""],
    ["cmd opt -o ", Any, () => arg(opt(), 0), ""],
    ["cmd opt -oarg", Args, () => optionArg(opt(), "-o"), "arg"],
    ["cmd -m ", Args, () => optionArg(cmd, "-m"), ""],
    ["cmd -marg", Args, () => optionArg(cmd, "-m"), "arg"],
  ])("%j", (...row) => check(row));

  it("follows a subcommand's loadSpec", async () => {
    const result = await parse("cmd loadSpec ");
    expect(loadSpec).toHaveBeenLastCalledWith({ type: "global", name: "loadSpecName" });
    expect(result.node).toBe(specToLoad);
    expect(result.currentArg?.source).toBe(specToLoad.args[0]);
    expect(result.commandIndex).toBe(1);
    expect(result.flags).toBe(Any);
  });

  it("follows isModule arguments", async () => {
    const result = await parse("cmd module moduleName ");
    expect(loadSpec).toHaveBeenLastCalledWith({ type: "global", name: "python/moduleName" });
    expect(result.node).toBe(specToLoad);
  });

  it("parses the command after an isCommand argument with its own spec", async () => {
    const result = await parse("cmd sudo cmd man ");
    expect(result.commandIndex).toBe(2);
    expect(result.currentArg?.source).toBe(arg(child("man"), 0));
  });

  it("falls back to files when the command after isCommand has no spec", async () => {
    const result = await parse("cmd sudo unknown ");
    expect(result.fallback).toBe(true);
    expect(result.commandIndex).toBe(2);
  });

  it("applies the repeat limit to parsing and suggestions alike", async () => {
    // `-n` is not repeatable, so a second `-n` cannot be an option.
    const result = await parse("cmd man -n -n ");
    expect(result.passedOptions.map((option) => option.name[0])).toEqual(["-n"]);
    expect(result.currentArg?.source).toBe(arg(child("man"), 1));
  });

  it("keeps argument objects identical while the last token changes", async () => {
    const ctx = context();
    const first = await parseArguments(["cmd", "man", "a"], ctx);
    const second = await parseArguments(["cmd", "man", "ab"], ctx);
    expect(second.currentArg).toBe(first.currentArg);
    const chainA = await parseArguments(["cmd", "man", "-mx"], ctx);
    const chainB = await parseArguments(["cmd", "man", "-mxy"], ctx);
    expect(chainB.currentArg).toBe(chainA.currentArg);
  });
});
