import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it, vi } from "vitest";
import { parseColor } from "./colors";
import { DARK_THEME, LIGHT_THEME, loadTheme, resolveTheme, themeVariables } from "./theme";

const dracula = {
  version: "1.0",
  theme: {
    textColor: "#f8f8f2",
    backgroundColor: "#282a36",
    matchBackgroundColor: "#6272a4",
    selection: { textColor: "#f8f8f2", backgroundColor: "#44475a" },
    description: { textColor: "#bd93f9", borderColor: "#44475a" },
  },
};

describe("resolveTheme", () => {
  it("maps every v1.0 key to its colour", () => {
    const colors = resolveTheme(dracula);
    expect(colors.mainBg).toEqual({ r: 40, g: 42, b: 54, a: 1 });
    expect(colors.mainText).toEqual({ r: 248, g: 248, b: 242, a: 1 });
    expect(colors.matchingBg).toEqual({ r: 98, g: 114, b: 164, a: 1 });
    expect(colors.selectedBg).toEqual({ r: 68, g: 71, b: 90, a: 1 });
    expect(colors.selectedText).toEqual({ r: 248, g: 248, b: 242, a: 1 });
    expect(colors.descriptionText).toEqual({ r: 189, g: 147, b: 249, a: 1 });
    expect(colors.descriptionBorder).toEqual({ r: 68, g: 71, b: 90, a: 1 });
  });

  it("uses rgb(106, 142, 218) for a missing selection match colour (visible, unlike upstream)", () => {
    expect(resolveTheme(dracula).selectedMatchingBg).toEqual({ r: 106, g: 142, b: 218, a: 1 });
  });

  it("falls back to dark per colour, not for the whole theme", () => {
    const colors = resolveTheme({ version: "1.0", theme: { backgroundColor: "#000000", matchBackgroundColor: "#00000" } });
    expect(colors.mainBg).toEqual({ r: 0, g: 0, b: 0, a: 1 });
    expect(colors.matchingBg).toEqual(DARK_THEME.matchingBg);
    expect(colors.descriptionBorder).toEqual(DARK_THEME.descriptionBorder);
  });

  it("renders anything without a theme object as dark", () => {
    expect(resolveTheme({ shade0: "#ffffff" })).toEqual(DARK_THEME);
    expect(resolveTheme(null)).toEqual(DARK_THEME);
    expect(resolveTheme("nope")).toEqual(DARK_THEME);
  });
});

describe("themeVariables", () => {
  it("emits channels and an alpha for each colour", () => {
    const variables = themeVariables(resolveTheme({ theme: { selection: { backgroundColor: "#396cb335" } } }));
    expect(variables["--selected-bg-color"]).toBe("57 108 179");
    expect(variables["--selected-bg-color-alpha"]).toBe("0.208");
    expect(variables["--main-bg-color"]).toBe("48 48 48");
    expect(variables["--main-bg-color-alpha"]).toBe("1");
    expect(Object.keys(variables)).toHaveLength(18);
  });

  it("applies the highlights' 80% opacity on top of the theme's alpha", () => {
    const variables = themeVariables(resolveTheme({ theme: { matchBackgroundColor: "#c7924a80" } }));
    expect(variables["--matching-bg-color-alpha"]).toBe("0.502");
    expect(variables["--matching-bg-color-mark-alpha"]).toBe("0.402");
    expect(variables["--selected-matching-bg-color-mark-alpha"]).toBe("0.8");
  });

  it("matches the spec's built-in values", () => {
    expect(themeVariables(DARK_THEME)).toMatchObject({
      "--main-bg-color": "48 48 48",
      "--main-text-color": "180 180 180",
      "--matching-bg-color": "95 89 56",
      "--selected-bg-color": "30 90 199",
      "--selected-text-color": "253 253 253",
      "--selected-matching-bg-color": "106 142 218",
      "--description-text-color": "180 180 180",
      "--description-border-color": "65 65 65",
    });
    expect(themeVariables(LIGHT_THEME)).toMatchObject({
      "--main-bg-color": "254 254 254",
      "--main-text-color": "7 7 7",
      "--matching-bg-color": "255 239 152",
      "--selected-bg-color": "41 105 218",
      "--description-border-color": "199 199 199",
    });
  });
});

describe("loadTheme", () => {
  const loader = vi.fn(async (name: string) => {
    if (name === "dracula") {
      return dracula;
    }
    throw new Error("missing");
  });

  it("resolves built-ins without loading", async () => {
    expect(await loadTheme(undefined, false, loader)).toBe(DARK_THEME);
    expect(await loadTheme("dark", false, loader)).toBe(DARK_THEME);
    expect(await loadTheme("light", true, loader)).toBe(LIGHT_THEME);
    expect(await loadTheme("system", true, loader)).toBe(DARK_THEME);
    expect(await loadTheme("system", false, loader)).toBe(LIGHT_THEME);
    expect(loader).not.toHaveBeenCalled();
  });

  it("loads files and falls back to dark when one is missing", async () => {
    expect((await loadTheme("dracula", false, loader)).mainBg).toEqual({ r: 40, g: 42, b: 54, a: 1 });
    expect(await loadTheme("no-such-theme", false, loader)).toBe(DARK_THEME);
  });
});

// Fig's own themes, when scripts/bundle.sh has fetched them (they are not part of the repo).
const INSTALLED = fileURLToPath(new URL("../../../../build/.cache/fig-themes/themes", import.meta.url));

describe.skipIf(!existsSync(INSTALLED))("Fig themes", () => {
  const files = existsSync(INSTALLED) ? readdirSync(INSTALLED).filter((file) => file.endsWith(".json")) : [];

  it.each(files)("%s parses every colour it defines", (file) => {
    const json = JSON.parse(readFileSync(join(INSTALLED, file), "utf8")) as { theme: Record<string, unknown> };
    const theme = json.theme;
    const selection = theme.selection as Record<string, unknown>;
    const description = theme.description as Record<string, unknown>;
    const values = [
      theme.textColor,
      theme.backgroundColor,
      theme.matchBackgroundColor,
      selection.textColor,
      selection.backgroundColor,
      description.textColor,
      description.borderColor,
      ...(selection.matchBackgroundColor ? [selection.matchBackgroundColor] : []),
    ];
    const unreadable = values.filter((value) => parseColor(value) === null);
    // halloween.json ships the 5-digit "#00000"; that one colour falls back to dark.
    expect(unreadable).toEqual(file === "halloween.json" ? ["#00000"] : []);
  });

  it("gives darkclown its black background (upstream emitted invalid CSS)", () => {
    const json: unknown = JSON.parse(readFileSync(join(INSTALLED, "darkclown.json"), "utf8"));
    expect(resolveTheme(json).mainBg).toEqual({ r: 0, g: 0, b: 0, a: 1 });
  });
});
