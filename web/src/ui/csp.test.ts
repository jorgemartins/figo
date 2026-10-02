import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const INDEX = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../index.html");

function policy(): Map<string, string[]> {
  const html = readFileSync(INDEX, "utf8");
  const content = /http-equiv="Content-Security-Policy"\s+content="([^"]*)"/.exec(html)?.[1] ?? "";
  return new Map(
    content
      .split(";")
      .map((directive) => directive.trim().split(/\s+/))
      .filter((parts) => parts[0])
      .map(([name, ...sources]) => [name ?? "", sources]),
  );
}

describe("Content-Security-Policy (review M11)", () => {
  it("loads images only from the app or inline", () => {
    expect(policy().get("img-src")).toEqual(["fig:", "figo:", "data:"]);
  });

  it("connects only to the page's origin and the app's scheme", () => {
    expect(policy().get("connect-src")).toEqual(["'self'", "figo:"]);
  });

  it("leaves scripts and styles alone (served from figo:// in the app and by Vite in development)", () => {
    expect(policy().has("default-src")).toBe(false);
    expect(policy().has("script-src")).toBe(false);
    expect(policy().has("style-src")).toBe(false);
  });
});
