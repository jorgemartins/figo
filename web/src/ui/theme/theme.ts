import { channels, parseColor, type Rgba } from "./colors";

export type ColorRole =
  | "mainBg"
  | "mainText"
  | "matchingBg"
  | "selectedBg"
  | "selectedText"
  | "selectedMatchingBg"
  | "descriptionText"
  | "descriptionBorder";

export type ThemeColors = Record<ColorRole, Rgba>;

/** The stylesheet reads `rgb(var(<name>) / var(<name>-alpha))`. */
export const COLOR_VARIABLES: Record<ColorRole, string> = {
  mainBg: "--main-bg-color",
  mainText: "--main-text-color",
  matchingBg: "--matching-bg-color",
  selectedBg: "--selected-bg-color",
  selectedText: "--selected-text-color",
  selectedMatchingBg: "--selected-matching-bg-color",
  descriptionText: "--description-text-color",
  descriptionBorder: "--description-border-color",
};

const rgb = (r: number, g: number, b: number): Rgba => ({ r, g, b, a: 1 });

export const DARK_THEME: ThemeColors = {
  mainBg: rgb(48, 48, 48),
  mainText: rgb(180, 180, 180),
  matchingBg: rgb(95, 89, 56),
  selectedBg: rgb(30, 90, 199),
  selectedText: rgb(253, 253, 253),
  selectedMatchingBg: rgb(106, 142, 218),
  descriptionText: rgb(180, 180, 180),
  descriptionBorder: rgb(65, 65, 65),
};

export const LIGHT_THEME: ThemeColors = {
  mainBg: rgb(254, 254, 254),
  mainText: rgb(7, 7, 7),
  matchingBg: rgb(255, 239, 152),
  selectedBg: rgb(41, 105, 218),
  selectedText: rgb(253, 253, 253),
  selectedMatchingBg: rgb(106, 142, 218),
  descriptionText: rgb(7, 7, 7),
  descriptionBorder: rgb(199, 199, 199),
};

/** Used when a theme leaves `selection.matchBackgroundColor` out. */
const DEFAULT_SELECTED_MATCH = "rgb(106, 142, 218)";

function record(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

/**
 * Turns a theme file (schema v1.0: `{ theme: { textColor, backgroundColor, … } }`) into colours.
 * Each colour that is missing or unparsable falls back to the dark theme's value on its own;
 * upstream dropped the whole theme for a missing nested object and emitted invalid CSS for colours
 * it could not parse. A file without a `theme` object (the never-shipped v2 shade/accent format)
 * renders as dark, as it effectively did upstream.
 */
export function resolveTheme(file: unknown): ThemeColors {
  const theme = record(record(file).theme);
  const selection = record(theme.selection);
  const description = record(theme.description);
  const sources: Record<ColorRole, unknown> = {
    mainBg: theme.backgroundColor,
    mainText: theme.textColor,
    matchingBg: theme.matchBackgroundColor,
    selectedBg: selection.backgroundColor,
    selectedText: selection.textColor,
    selectedMatchingBg: selection.matchBackgroundColor ?? DEFAULT_SELECTED_MATCH,
    descriptionText: description.textColor,
    descriptionBorder: description.borderColor,
  };
  const colors = { ...DARK_THEME };
  for (const role of Object.keys(sources) as ColorRole[]) {
    colors[role] = parseColor(sources[role]) ?? DARK_THEME[role];
  }
  return colors;
}

/** Match highlights are drawn at 80% of their colour's opacity. */
const HIGHLIGHT_OPACITY = 0.8;

/**
 * CSS custom properties for the popup root: `--x: r g b` plus `--x-alpha: a`, and for the two
 * highlight colours `--x-mark-alpha` with the 80% already applied (computed here rather than with
 * calc() inside rgb(), which older WebKit may not accept).
 */
export function themeVariables(colors: ThemeColors): Record<string, string> {
  const variables: Record<string, string> = {};
  for (const role of Object.keys(COLOR_VARIABLES) as ColorRole[]) {
    const name = COLOR_VARIABLES[role];
    variables[name] = channels(colors[role]);
    variables[`${name}-alpha`] = String(colors[role].a);
    if (role === "matchingBg" || role === "selectedMatchingBg") {
      variables[`${name}-mark-alpha`] = String(Math.round(colors[role].a * HIGHLIGHT_OPACITY * 1000) / 1000);
    }
  }
  return variables;
}

export type ThemeLoader = (name: string) => Promise<unknown>;

/** Reads `<name>.json` from the app, which serves user themes over bundled ones. */
export const fetchThemeFile: ThemeLoader = async (name) => {
  const response = await fetch(`figo://themes/${encodeURIComponent(name)}.json`);
  if (!response.ok) {
    throw new Error(`Theme "${name}" could not be loaded (${response.status})`);
  }
  return (await response.json()) as unknown;
};

/** The built-in a setting names without loading anything, or null when a file must be loaded. */
export function builtInTheme(setting: string | undefined, systemIsDark: boolean): ThemeColors | null {
  switch (setting) {
    case undefined:
    case "":
    case "dark":
      return DARK_THEME;
    case "light":
      return LIGHT_THEME;
    case "system":
      return systemIsDark ? DARK_THEME : LIGHT_THEME;
    default:
      return null;
  }
}

/** Resolves `autocomplete.theme`. Unset, missing and unreadable themes are dark, as upstream. */
export async function loadTheme(
  setting: string | undefined,
  systemIsDark: boolean,
  loader: ThemeLoader,
): Promise<ThemeColors> {
  const builtIn = builtInTheme(setting, systemIsDark);
  if (builtIn || setting === undefined) {
    return builtIn ?? DARK_THEME;
  }
  try {
    return resolveTheme(await loader(setting));
  } catch {
    return DARK_THEME;
  }
}
