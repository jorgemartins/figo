export interface Rgba {
  r: number;
  g: number;
  b: number;
  /** 0…1 */
  a: number;
}

const HEX = /^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i;
const FUNCTIONAL = /^rgba?\((.*)\)$/i;
const NUMBER = /^[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?%?$/i;

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function round(value: number): number {
  return Math.round(value * 1000) / 1000;
}

function parseHex(digits: string): Rgba {
  const full = digits.length <= 4 ? [...digits].map((d) => d + d).join("") : digits;
  const channel = (i: number) => parseInt(full.slice(i * 2, i * 2 + 2), 16);
  return {
    r: channel(0),
    g: channel(1),
    b: channel(2),
    // Upstream multiplied the channels by this instead, turning translucent colours into darker
    // opaque ones; it is a real alpha here.
    a: full.length === 8 ? round(channel(3) / 255) : 1,
  };
}

function parseChannel(token: string): number | null {
  if (!NUMBER.test(token)) {
    return null;
  }
  const value = token.endsWith("%") ? (parseFloat(token) / 100) * 255 : parseFloat(token);
  return round(clamp(value, 0, 255));
}

function parseAlpha(token: string): number | null {
  if (!NUMBER.test(token)) {
    return null;
  }
  const value = token.endsWith("%") ? parseFloat(token) / 100 : parseFloat(token);
  return round(clamp(value, 0, 1));
}

/**
 * Accepts `rgb()`/`rgba()` in both the comma form, with or without spaces (`rgb(0, 255, 0)`,
 * which upstream's regex rejected), and the space form with an optional `/ alpha`.
 */
function parseFunctional(body: string): Rgba | null {
  let tokens: string[];
  let alphaToken: string | undefined;
  if (body.includes(",")) {
    tokens = body.split(",").map((t) => t.trim());
    if (tokens.length === 4) {
      alphaToken = tokens.pop();
    }
  } else {
    const [channels = "", alpha, ...extra] = body.split("/").map((t) => t.trim());
    if (extra.length > 0) {
      return null;
    }
    tokens = channels.split(/\s+/).filter(Boolean);
    alphaToken = alpha;
  }
  if (tokens.length !== 3) {
    return null;
  }
  const [r, g, b] = tokens.map(parseChannel);
  const a = alphaToken === undefined ? 1 : parseAlpha(alphaToken);
  if (r == null || g == null || b == null || a == null) {
    return null;
  }
  return { r, g, b, a };
}

/** Parses a theme colour, or returns null when it is not a colour this loader understands. */
export function parseColor(value: unknown): Rgba | null {
  if (typeof value !== "string") {
    return null;
  }
  const color = value.trim();
  const hex = HEX.exec(color);
  if (hex?.[1]) {
    return parseHex(hex[1]);
  }
  const functional = FUNCTIONAL.exec(color);
  if (functional) {
    return parseFunctional(functional[1] ?? "");
  }
  if (color.toLowerCase() === "transparent") {
    return { r: 0, g: 0, b: 0, a: 0 };
  }
  return null;
}

/** `r g b` channels, the form the stylesheet combines with an alpha: `rgb(var(--x) / …)`. */
export function channels(color: Rgba): string {
  return `${color.r} ${color.g} ${color.b}`;
}
