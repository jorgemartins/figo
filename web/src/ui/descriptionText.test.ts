import { describe, expect, it } from "vitest";
import type { Suggestion } from "../core/contract";
import { footerContent, itemDescription } from "./descriptionText";

function item(type: Suggestion["type"], description?: string): Suggestion {
  return { type, names: ["x"], description, match: { nameIndex: 0, ranges: [] } };
}

describe("itemDescription", () => {
  it("uses the description, trimmed", () => {
    expect(itemDescription(item("subcommand", "  Install packages \n"))).toBe("Install packages");
  });

  it("says file or folder for those without a description", () => {
    expect(itemDescription(item("folder"))).toBe("folder");
    expect(itemDescription(item("file", " "))).toBe("file");
    expect(itemDescription(item("arg"))).toBe("");
    expect(itemDescription(undefined)).toBe("");
  });
});

describe("footerContent", () => {
  const argument = { name: "branch", description: "The branch to switch to" };

  it("prefers the item's own description", () => {
    expect(footerContent(item("arg", "main"), argument)).toEqual({ name: "", text: "main" });
  });

  it("falls back to the current argument's name and description", () => {
    expect(footerContent(item("arg"), argument)).toEqual({ name: "branch", text: "The branch to switch to" });
    expect(footerContent(item("arg"), null)).toEqual({ name: "", text: "" });
  });
});
