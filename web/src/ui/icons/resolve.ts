import type { Suggestion } from "../../core/contract";
import { isAssetName, type AssetName } from "./assets";

/** A small badge on the bottom-right of a named icon: `fig://icon?type=…&color=…&badge=…`. */
export interface CornerBadge {
  text: string;
  /** 6 hex digits without `#`; the badge tile is white without one. */
  color?: string;
}

export type IconSpec =
  /** An emoji or a few characters, drawn as text. */
  | { kind: "text"; text: string }
  /** One of Figo's own icons. */
  | { kind: "asset"; name: AssetName; badge?: CornerBadge }
  /** The template tile tinted with `color`, with `badge` centred on it. */
  | { kind: "template"; color?: string; badge?: string }
  /**
   * An image the page cannot draw itself: a `fig://` URL the app answers with a PNG, or any other
   * URL. `fallback` is drawn when it fails to load, or straight away when no app can answer.
   */
  | { kind: "image"; url: string; fallback: IconSpec | null; badge?: CornerBadge };

export interface IconContext {
  /**
   * Absolute directory, with a trailing slash, whose entries the file and folder suggestions are.
   * When known, those rows show the Finder icon of the real path.
   */
  iconDirectory?: string;
}

const SAFE_PROTOCOLS = new Set(["fig:", "figo:", "icon:", "http:", "https:", "data:", "file:", "blob:"]);
const HEX_COLOR = /^[0-9a-f]{6}$/i;

function colorParam(url: URL): string | undefined {
  const color = url.searchParams.get("color");
  return color && HEX_COLOR.test(color) ? color : undefined;
}

function cornerBadge(url: URL): CornerBadge | undefined {
  const text = url.searchParams.get("badge");
  return text ? { text, color: colorParam(url) } : undefined;
}

function encodePath(path: string): string {
  return path.split("/").map(encodeURIComponent).join("/");
}

/** Fallback for a path the app could not answer: a folder when it ends with `/`, else a file. */
function pathFallback(path: string): IconSpec {
  return { kind: "asset", name: path.endsWith("/") ? "finder-folder" : "file" };
}

function resolveFigUrl(url: URL): IconSpec {
  // `fig:///Users/…` is the path form with the host left out.
  const host = url.host === "" ? "path" : url.host;

  if (host === "template") {
    return { kind: "template", color: colorParam(url), badge: url.searchParams.get("badge") ?? undefined };
  }

  if (host === "icon") {
    const type = url.searchParams.get("type") ?? url.searchParams.get("asset");
    const badge = cornerBadge(url);
    if (type && isAssetName(type)) {
      return { kind: "asset", name: type, badge };
    }
    if (type) {
      // A file extension or UTI: the app answers with the system icon for that type.
      return {
        kind: "image",
        url: `fig://icon?type=${encodeURIComponent(type)}`,
        fallback: { kind: "asset", name: "file" },
        badge,
      };
    }
    return { kind: "asset", name: "box", badge };
  }

  if (host === "path") {
    let path = url.pathname;
    try {
      path = decodeURIComponent(path);
    } catch {
      // A stray "%" in a file name: keep the path as the URL parser left it.
    }
    return { kind: "image", url: `fig://path${encodePath(path)}`, fallback: pathFallback(path) };
  }

  return { kind: "image", url: `fig://${host}${url.pathname}${url.search}`, fallback: null };
}

function parseUrl(icon: string): URL | null {
  try {
    const url = new URL(icon);
    return SAFE_PROTOCOLS.has(url.protocol) ? url : null;
  } catch {
    return null;
  }
}

function extensionOf(name: string): string | undefined {
  const dot = name.lastIndexOf(".");
  return dot > 0 && dot < name.length - 1 ? name.slice(dot + 1).toLowerCase() : undefined;
}

function defaultIcon(suggestion: Pick<Suggestion, "type" | "names">, context: IconContext): IconSpec {
  const name = suggestion.names[0] ?? "";
  switch (suggestion.type) {
    case "folder":
    case "file": {
      if (context.iconDirectory !== undefined) {
        const path = `${context.iconDirectory}${name}`;
        return { kind: "image", url: `fig://path${encodePath(path)}`, fallback: pathFallback(path) };
      }
      if (suggestion.type === "folder") {
        return { kind: "asset", name: "finder-folder" };
      }
      const extension = extensionOf(name);
      return extension
        ? { kind: "image", url: `fig://icon?type=${encodeURIComponent(extension)}`, fallback: { kind: "asset", name: "file" } }
        : { kind: "asset", name: "file" };
    }
    case "subcommand":
      return { kind: "asset", name: "command" };
    case "option":
      return { kind: "asset", name: "option" };
    case "auto-execute":
      return { kind: "asset", name: "carrot" };
    case "shortcut":
      return { kind: "template", color: "3498db", badge: "💡" };
    case "mixin":
      return { kind: "template", color: "628dad", badge: "➡️" };
    case "history":
      // Upstream's history items always carry this emoji.
      return { kind: "text", text: "📚" };
    default:
      return { kind: "asset", name: "box" };
  }
}

/**
 * Decides how a row's icon is drawn, in upstream's order: a string of fewer than 4 UTF-16 units is
 * text (emoji); a URL is an image (with `fig:` URLs mapped onto Figo's own assets where possible);
 * any other string is text; no icon means the default for the suggestion's type.
 */
export function resolveIcon(suggestion: Pick<Suggestion, "icon" | "type" | "names">, context: IconContext = {}): IconSpec {
  const { icon } = suggestion;
  if (icon === undefined || icon === "") {
    return defaultIcon(suggestion, context);
  }
  if (icon.length < 4) {
    return { kind: "text", text: icon };
  }
  const url = parseUrl(icon);
  if (!url) {
    return { kind: "text", text: icon };
  }
  if (url.protocol === "fig:" || url.protocol === "icon:") {
    return resolveFigUrl(url);
  }
  return { kind: "image", url: url.href, fallback: null };
}
