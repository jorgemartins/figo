import type { Settings } from "../bridge/contract";

/** The root font size when `autocomplete.fontSize` is unset; every rem-based length derives from it. */
export const DEFAULT_FONT_SIZE = 12.8;
/** Row height = font size × this (20px at 12.8px). */
export const ROW_HEIGHT_FACTOR = 1.5625;
/** Icon box = row height × this (15px at 20px). */
export const ICON_SIZE_FACTOR = 0.75;
export const DEFAULT_WIDTH = 320;
export const DEFAULT_HEIGHT = 140;
/** Added to the default width while the list shows shell history. */
export const HISTORY_EXTRA_WIDTH = 50;
/** Width of the side description panel. A literal pixel value: it does not scale. */
export const POPOUT_WIDTH = 200;

export interface Metrics {
  /** Root font size in px (`--rem`): names, descriptions and every rem-based length. */
  fontSize: number;
  /** Height of one row, and of the description footer. */
  itemSize: number;
  iconSize: number;
  /** Width of the list container. */
  listWidth: number;
  /** Maximum height of rows plus footer. */
  maxHeight: number;
  /** Maximum height of the side panel; the plain height setting, unaffected by the session scale. */
  panelMaxHeight: number;
}

function positiveNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;
}

/**
 * Sizes for the current settings. `scale` is the session-only factor of increaseSize/decreaseSize:
 * it multiplies the font, row, width and height together. Width and height do not follow the font
 * size on their own.
 */
export function computeMetrics(settings: Settings, scale: number, historyMode: boolean): Metrics {
  const factor = positiveNumber(scale) ?? 1;
  const baseFont = positiveNumber(settings["autocomplete.fontSize"]) ?? DEFAULT_FONT_SIZE;
  const historyWidened =
    historyMode || ["show", "history_only"].includes(settings["beta.history.mode"] as string);
  const baseWidth =
    positiveNumber(settings["autocomplete.width"]) ?? DEFAULT_WIDTH + (historyWidened ? HISTORY_EXTRA_WIDTH : 0);
  const baseHeight = positiveNumber(settings["autocomplete.height"]) ?? DEFAULT_HEIGHT;

  const fontSize = baseFont * factor;
  const itemSize = fontSize * ROW_HEIGHT_FACTOR;
  return {
    fontSize,
    itemSize,
    iconSize: itemSize * ICON_SIZE_FACTOR,
    listWidth: baseWidth * factor,
    maxHeight: baseHeight * factor,
    panelMaxHeight: baseHeight,
  };
}

/** `autocomplete.fontFamily`, or undefined to keep Monaco for names and the system font for descriptions. */
export function fontFamilySetting(settings: Settings): string | undefined {
  const value = settings["autocomplete.fontFamily"];
  return typeof value === "string" && value.trim() !== "" ? value : undefined;
}

export function alwaysShowDescription(settings: Settings): boolean {
  return settings["autocomplete.alwaysShowDescription"] === true;
}

export function themeSetting(settings: Settings): string | undefined {
  const value = settings["autocomplete.theme"];
  return typeof value === "string" && value !== "" ? value : undefined;
}
