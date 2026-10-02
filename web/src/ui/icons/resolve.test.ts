import { describe, expect, it } from "vitest";
import type { Suggestion } from "../../core/contract";
import { resolveIcon } from "./resolve";

function item(type: Suggestion["type"], icon?: string, name = "thing"): Pick<Suggestion, "icon" | "type" | "names"> {
  return { type, icon, names: [name] };
}

describe("resolveIcon: strings", () => {
  it("draws strings shorter than 4 UTF-16 units as text", () => {
    expect(resolveIcon(item("arg", "🔥"))).toEqual({ kind: "text", text: "🔥" });
    expect(resolveIcon(item("history", "📚"))).toEqual({ kind: "text", text: "📚" });
    expect(resolveIcon(item("arg", "abc"))).toEqual({ kind: "text", text: "abc" });
  });

  it("draws longer strings that are not URLs as text", () => {
    expect(resolveIcon(item("arg", "hello world"))).toEqual({ kind: "text", text: "hello world" });
    // A colon alone does not make an icon URL.
    expect(resolveIcon(item("arg", "note:thing"))).toEqual({ kind: "text", text: "note:thing" });
  });
});

describe("resolveIcon: fig:// URLs", () => {
  it("maps named icons onto Figo's own assets", () => {
    expect(resolveIcon(item("arg", "fig://icon?type=npm"))).toEqual({ kind: "asset", name: "npm", badge: undefined });
    expect(resolveIcon(item("arg", "fig://icon?type=git"))).toEqual({ kind: "asset", name: "git", badge: undefined });
    expect(resolveIcon(item("arg", "fig://icon?asset=gear"))).toEqual({ kind: "asset", name: "gear", badge: undefined });
  });

  it("asks the app for unknown types (file extensions), with a file fallback", () => {
    expect(resolveIcon(item("arg", "fig://icon?type=pdf"))).toEqual({
      kind: "image",
      url: "fig://icon?type=pdf",
      fallback: { kind: "asset", name: "file" },
      badge: undefined,
    });
  });

  it("adds a corner badge to named icons", () => {
    expect(resolveIcon(item("arg", "fig://icon?type=docker&color=e67e22&badge=2"))).toEqual({
      kind: "asset",
      name: "docker",
      badge: { text: "2", color: "e67e22" },
    });
  });

  it("reads template colour and badge, ignoring colours that are not 6 hex digits", () => {
    expect(resolveIcon(item("arg", "fig://template?color=3498db&badge=💡"))).toEqual({
      kind: "template",
      color: "3498db",
      badge: "💡",
    });
    expect(resolveIcon(item("arg", "fig://template?color=%23ff0000&badge=x"))).toEqual({
      kind: "template",
      color: undefined,
      badge: "x",
    });
    expect(resolveIcon(item("arg", "fig://template"))).toEqual({ kind: "template", color: undefined, badge: undefined });
  });

  it("serves paths through the app, falling back to a folder or file drawing", () => {
    expect(resolveIcon(item("arg", "fig://path/Users/me/Beta Projects/"))).toEqual({
      kind: "image",
      url: "fig://path/Users/me/Beta%20Projects/",
      fallback: { kind: "asset", name: "finder-folder" },
    });
    expect(resolveIcon(item("arg", "fig://path/Users/me/notes.md"))).toEqual({
      kind: "image",
      url: "fig://path/Users/me/notes.md",
      fallback: { kind: "asset", name: "file" },
    });
  });

  it("treats a missing host as the path form", () => {
    expect(resolveIcon(item("arg", "fig:///Users/me/a#b.txt"))).toMatchObject({
      kind: "image",
      fallback: { kind: "asset", name: "file" },
    });
    const spec = resolveIcon(item("arg", "fig:///Users/me/dir/"));
    expect(spec).toEqual({ kind: "image", url: "fig://path/Users/me/dir/", fallback: { kind: "asset", name: "finder-folder" } });
  });
});

describe("resolveIcon: other URLs", () => {
  it("uses web images as they are, with nothing drawn when they fail", () => {
    expect(resolveIcon(item("arg", "https://example.com/icon.png"))).toEqual({
      kind: "image",
      url: "https://example.com/icon.png",
      fallback: null,
    });
  });
});

describe("resolveIcon: defaults per type", () => {
  it.each([
    ["subcommand", { kind: "asset", name: "command" }],
    ["option", { kind: "asset", name: "option" }],
    ["arg", { kind: "asset", name: "box" }],
    ["special", { kind: "asset", name: "box" }],
    ["auto-execute", { kind: "asset", name: "carrot" }],
    ["shortcut", { kind: "template", color: "3498db", badge: "💡" }],
    ["mixin", { kind: "template", color: "628dad", badge: "➡️" }],
    ["history", { kind: "text", text: "📚" }],
  ] as const)("%s", (type, expected) => {
    expect(resolveIcon(item(type))).toEqual(expected);
  });

  it("draws folders and files without a known directory", () => {
    expect(resolveIcon(item("folder", undefined, "Sites/"))).toEqual({ kind: "asset", name: "finder-folder" });
    expect(resolveIcon(item("file", undefined, "Makefile"))).toEqual({ kind: "asset", name: "file" });
    expect(resolveIcon(item("file", undefined, "index.TS"))).toEqual({
      kind: "image",
      url: "fig://icon?type=ts",
      fallback: { kind: "asset", name: "file" },
    });
  });

  it("asks for the real Finder icon when the directory is known", () => {
    expect(resolveIcon(item("folder", undefined, "Sites/"), { iconDirectory: "/Users/me/" })).toEqual({
      kind: "image",
      url: "fig://path/Users/me/Sites/",
      fallback: { kind: "asset", name: "finder-folder" },
    });
  });
});
