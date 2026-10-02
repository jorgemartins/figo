import { describe, expect, it } from "vitest";
import { ICON_ASSETS, isAssetName, svgDataUrl, templateSvg } from "./assets";

/** Every name upstream resolves through its icon CDN, plus the bundled fallbacks. */
const NAMED = [
  "alert", "android", "apple", "asterisk", "aws", "azure", "box", "carrot", "characters", "command",
  "commandkey", "commit", "cpu", "database", "discord", "docker", "firebase", "flag", "gcloud", "gear",
  "git", "github", "gitlab", "gradle", "heroku", "invite", "kubernetes", "netlify", "node", "npm",
  "okteto", "option", "package", "slack", "string", "template", "twitter", "vercel", "yarn",
  "symlink", "folder", "file",
];

/** A minimal well-formedness check: balanced tags and no attribute given twice in one tag. */
function wellFormed(svg: string): string | null {
  const stack: string[] = [];
  for (const match of svg.matchAll(/<(\/?)([a-zA-Z]+)([^>]*?)(\/?)>/g)) {
    const [, closing, name = "", attributes = "", selfClosing] = match;
    const names = [...attributes.matchAll(/([\w:-]+)=/g)].map((m) => m[1]);
    const duplicate = names.find((n, i) => names.indexOf(n) !== i);
    if (duplicate) {
      return `duplicate ${duplicate} on <${name}>`;
    }
    if (closing) {
      if (stack.pop() !== name) {
        return `unbalanced </${name}>`;
      }
    } else if (!selfClosing) {
      stack.push(name);
    }
  }
  return stack.length === 0 ? null : `unclosed <${stack.join(">, <")}>`;
}

describe("icon assets", () => {
  it("covers every named icon", () => {
    expect(NAMED.filter((name) => !isAssetName(name))).toEqual([]);
  });

  it.each(Object.entries(ICON_ASSETS))("%s is a well-formed SVG", (_name, svg) => {
    expect(svg.startsWith('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">')).toBe(true);
    expect(wellFormed(svg)).toBeNull();
    expect(svg).not.toMatch(/NaN|undefined/);
  });

  it("tints the template", () => {
    expect(templateSvg("3498db")).toContain('fill="#3498db"');
    expect(templateSvg(undefined)).toBe(ICON_ASSETS.template);
  });

  it("encodes data URLs", () => {
    expect(svgDataUrl("<svg/>")).toBe("data:image/svg+xml;charset=utf-8,%3Csvg%2F%3E");
  });

  it("does not treat inherited object keys as assets", () => {
    expect(isAssetName("toString")).toBe(false);
    expect(isAssetName("constructor")).toBe(false);
  });
});
