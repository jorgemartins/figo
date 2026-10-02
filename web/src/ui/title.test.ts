import { describe, expect, it } from "vitest";
import type { Suggestion } from "../core/contract";
import { argumentText, nameSegments, prefixUnderline, titleSegments } from "./title";

function suggestion(names: string[], match: Suggestion["match"] = { nameIndex: 0, ranges: [] }, extra: Partial<Suggestion> = {}): Suggestion {
  return { type: "subcommand", names, match, ...extra };
}

describe("nameSegments", () => {
  it("returns the name as one plain run without matches", () => {
    expect(nameSegments("install", [], null)).toEqual([{ kind: "text", text: "install" }]);
  });

  it("marks matched ranges and merges adjacent ones", () => {
    expect(nameSegments("checkout", [[0, 2], [2, 3], [5, 6]], null)).toEqual([
      { kind: "match", text: "che" },
      { kind: "text", text: "ck" },
      { kind: "match", text: "o" },
      { kind: "text", text: "ut" },
    ]);
  });

  it("underlines the common prefix after the match", () => {
    const underline = { head: "dev", start: 2, end: 3 };
    expect(nameSegments("dev:serve", [[0, 2]], underline)).toEqual([
      { kind: "match", text: "de" },
      { kind: "prefix", text: "v" },
      { kind: "text", text: ":serve" },
    ]);
  });

  it("only underlines names that start with the prefix", () => {
    expect(nameSegments("db:reset", [], { head: "dev", start: 0, end: 3 })).toEqual([{ kind: "text", text: "db:reset" }]);
    expect(nameSegments("DEV", [], { head: "dev", start: 0, end: 3 })).toEqual([{ kind: "prefix", text: "DEV" }]);
  });

  it("ignores ranges outside the name", () => {
    expect(nameSegments("ab", [[1, 9]], null)).toEqual([
      { kind: "text", text: "a" },
      { kind: "match", text: "b" },
    ]);
  });
});

describe("titleSegments", () => {
  it("returns one segment list per name", () => {
    expect(titleSegments(suggestion(["install", "i"]), null)).toEqual([
      [{ kind: "text", text: "install" }],
      [{ kind: "text", text: "i" }],
    ]);
  });

  it("shows displayName instead of the names", () => {
    expect(titleSegments(suggestion(["--message", "-m"], undefined, { displayName: "-m, --message <msg>" }), null)).toEqual([
      [{ kind: "text", text: "-m, --message <msg>" }],
    ]);
  });

  it("highlights a typed prefix in every name that starts with it, as upstream", () => {
    const segments = titleSegments(suggestion(["install", "i"], { nameIndex: 0, ranges: [[0, 1]] }), null);
    expect(segments).toEqual([
      [
        { kind: "match", text: "i" },
        { kind: "text", text: "nstall" },
      ],
      [{ kind: "match", text: "i" }],
    ]);
  });

  it("does not mirror fuzzy (non-prefix) matches onto other names", () => {
    const segments = titleSegments(suggestion(["checkout", "co"], { nameIndex: 0, ranges: [[0, 1], [5, 6]] }), null);
    expect(segments[1]).toEqual([{ kind: "text", text: "co" }]);
  });
});

describe("prefixUnderline", () => {
  const list = [suggestion(["dev:serve"]), suggestion(["dev:serve:bg"])];

  it("takes the head of the selected item's first name", () => {
    expect(prefixUnderline({ suggestions: list, selectedIndex: 1, commonPrefix: [2, 9] })).toEqual({
      head: "dev:serve",
      start: 2,
      end: 9,
    });
  });

  it("is null without a range, with a bad range, or for a lone dash", () => {
    expect(prefixUnderline({ suggestions: list, selectedIndex: 0, commonPrefix: null })).toBeNull();
    expect(prefixUnderline({ suggestions: list, selectedIndex: 0, commonPrefix: [3, 3] })).toBeNull();
    expect(prefixUnderline({ suggestions: list, selectedIndex: 0, commonPrefix: [0, 99] })).toBeNull();
    expect(prefixUnderline({ suggestions: [suggestion(["-a"])], selectedIndex: 0, commonPrefix: [0, 1] })).toBeNull();
    expect(prefixUnderline({ suggestions: [], selectedIndex: 0, commonPrefix: [0, 1] })).toBeNull();
  });
});

describe("argumentText", () => {
  it("formats optional, required and variadic arguments like upstream", () => {
    expect(argumentText([{ name: "package", isOptional: true, isVariadic: true }])).toBe("[package...]");
    expect(argumentText([{ name: "file", isOptional: false, isVariadic: false }])).toBe("<file> ");
    expect(argumentText([{ name: "file", isOptional: false, isVariadic: true }])).toBe("<file...> ");
    expect(
      argumentText([
        { name: "branch", isOptional: true, isVariadic: false },
        { name: "pathspec", isOptional: true, isVariadic: true },
      ]),
    ).toBe("[branch] [pathspec...]");
    expect(
      argumentText([
        { name: "repository", isOptional: false, isVariadic: false },
        { name: "directory", isOptional: true, isVariadic: false },
      ]),
    ).toBe("<repository>  [directory]");
  });

  it("skips unnamed arguments", () => {
    expect(argumentText([{ name: "", isOptional: true, isVariadic: false }])).toBe("");
    expect(argumentText(undefined)).toBe("");
  });
});
