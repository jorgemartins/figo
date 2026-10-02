/**
 * Figo's own icon set, drawn on a 32×32 grid after the descriptions in the popup spec: a
 * full-bleed continuous-corner tile in a flat colour, darkened towards its edges (most at the
 * bottom), with a white glyph about 1px wide at display size. Brand names get generic glyphs on a
 * tile of a fitting colour; no brand marks are reproduced.
 */

const VIEW = 32;

/** A superellipse rather than a rounded rectangle: the continuous corners of macOS icons. */
function superellipse(exponent: number, points = 96): string {
  const half = VIEW / 2;
  const coords: string[] = [];
  for (let i = 0; i < points; i += 1) {
    const t = (i / points) * Math.PI * 2;
    const cos = Math.cos(t);
    const sin = Math.sin(t);
    const x = half + half * Math.sign(cos) * Math.abs(cos) ** (2 / exponent);
    const y = half + half * Math.sign(sin) * Math.abs(sin) ** (2 / exponent);
    coords.push(`${x.toFixed(2)} ${y.toFixed(2)}`);
  }
  return `M${coords.join("L")}Z`;
}

/** Exponent 4.6 gives corners equivalent to a ~7.6px radius, as measured on the originals. */
const TILE = superellipse(4.6);

/** Edge darkening: about 10% at the top and sides, about 30% along the bottom. */
const VIGNETTE =
  `<defs>` +
  `<linearGradient id="v" x1="0" y1="0" x2="0" y2="1">` +
  `<stop offset="0" stop-opacity=".1"/><stop offset=".11" stop-opacity="0"/>` +
  `<stop offset=".86" stop-opacity="0"/><stop offset="1" stop-opacity=".3"/>` +
  `</linearGradient>` +
  `<linearGradient id="h" x1="0" y1="0" x2="1" y2="0">` +
  `<stop offset="0" stop-opacity=".1"/><stop offset=".11" stop-opacity="0"/>` +
  `<stop offset=".89" stop-opacity="0"/><stop offset="1" stop-opacity=".1"/>` +
  `</linearGradient>` +
  `</defs>`;

const STROKE = `fill="none" stroke="#fff" stroke-linecap="round" stroke-linejoin="round"`;

function svg(body: string): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${VIEW} ${VIEW}">${body}</svg>`;
}

/** A tinted tile with a glyph on top. */
export function tile(fill: string, glyph = ""): string {
  return svg(`${VIGNETTE}<path d="${TILE}" fill="${fill}"/><path d="${TILE}" fill="url(#v)"/><path d="${TILE}" fill="url(#h)"/>${glyph}`);
}

function stroked(d: string, width = 1.8, ends: "round" | "sharp" = "round"): string {
  const style = ends === "round" ? STROKE : `fill="none" stroke="#fff" stroke-linecap="butt" stroke-linejoin="miter"`;
  return `<path d="${d}" ${style} stroke-width="${width}"/>`;
}

function dot(cx: number, cy: number, r: number, fill = "#fff"): string {
  return `<circle cx="${cx}" cy="${cy}" r="${r}" fill="${fill}"/>`;
}

function gear(): string {
  const teeth = 8;
  const outer = 9;
  const inner = 6.6;
  const parts: string[] = [];
  for (let i = 0; i < teeth; i += 1) {
    const base = (i / teeth) * Math.PI * 2;
    const step = (Math.PI * 2) / teeth;
    // Each tooth is slightly narrower at its tip than at its root.
    const angles: Array<[number, number]> = [
      [base - step * 0.29, inner],
      [base - step * 0.2, outer],
      [base + step * 0.2, outer],
      [base + step * 0.29, inner],
    ];
    for (const [angle, radius] of angles) {
      parts.push(`${(16 + radius * Math.cos(angle)).toFixed(2)} ${(16 + radius * Math.sin(angle)).toFixed(2)}`);
    }
  }
  const ring = `M${parts.join("L")}Z`;
  const hole = "M16 12.9a3.1 3.1 0 1 0 0 6.2a3.1 3.1 0 1 0 0-6.2Z";
  return `<path d="${ring}${hole}" fill="#fff" fill-rule="evenodd"/>`;
}

const CUBE = "M16 6.2L24.6 11V21L16 25.8L7.4 21V11ZM7.4 11L16 15.8L24.6 11M16 15.8V25.8";
const CLOUD =
  "M10.6 22.5H22.4C25 22.5 26.8 20.7 26.8 18.3C26.8 16 25 14.3 22.8 14.2C22.2 11.3 19.7 9.3 16.8 9.3C14.4 9.3 12.3 10.7 11.4 12.9C8.4 13.1 6 15.4 6 18.1C6 20.6 8 22.5 10.6 22.5Z";
const BUBBLE = "M9.5 8.5H22.5C23.9 8.5 25 9.6 25 11V18.5C25 19.9 23.9 21 22.5 21H15L10.5 24.6V21H9.5C8.1 21 7 19.9 7 18.5V11C7 9.6 8.1 8.5 9.5 8.5Z";
const HEXAGON = "M16 6L24.7 11V21L16 26L7.3 21V11Z";

/**
 * Every named icon `fig://icon?type=<name>` can refer to, plus the bundled fallbacks. Values are
 * complete SVG documents.
 */
export const ICON_ASSETS = {
  // Generic glyph tiles (upstream's own icons).
  command: tile(
    "#8839D1",
    stroked(
      "M21 10.4C20.2 8.4 18.4 7.4 16 7.4C13 7.4 10.9 9.1 10.9 11.7C10.9 14.5 13.3 15.3 16 16C18.8 16.7 21.1 17.7 21.1 20.5C21.1 23 18.9 24.6 16 24.6C13.4 24.6 11.6 23.6 10.8 21.6",
      1.7,
    ) + stroked("M16 4.6V27.4", 1.7),
  ),
  option: tile(
    "#5ACC5B",
    stroked("M11.6 12C11.6 9.3 13.6 7.6 16.2 7.6C18.8 7.6 20.7 9.3 20.7 11.7C20.7 14.3 18.6 15.1 17.1 16.3C16.4 16.9 16 17.7 16 19.3", 2.1) +
      dot(16, 23.9, 1.5),
  ),
  carrot: tile("#D13956", stroked("M9.4 9.6L23.4 16L9.4 22.4", 1.9, "sharp")),
  box: tile("#649BC9", stroked(CUBE, 1.7)),
  asterisk: tile("#3941D1", stroked("M16 10.6V22.4M10.9 13.5L21.1 19.5M10.9 19.5L21.1 13.5", 2.2)),
  flag: tile(
    "#3941D1",
    stroked("M8 17.4H13.2", 1.6) +
      stroked("M18.6 24.5V11.6C18.6 9.3 19.8 8 21.9 8C22.6 8 23.3 8.2 23.9 8.5M16 13.6H22.6", 1.6),
  ),
  alert: tile("#FFC528", stroked("M16 7.6V18.8", 2.6) + dot(16, 23.6, 1.7)),
  characters: tile(
    "#1E88FF",
    stroked("M6.4 23.2L11.4 8.6L16.4 23.2M8.2 18.2H14.6", 1.6) +
      stroked(
        "M19.2 14C19.8 12.9 20.9 12.4 22.3 12.4C24.3 12.4 25.6 13.5 25.6 15.6V23.2M25.6 17.6C24.7 17.3 23.6 17.2 22.4 17.3C20.3 17.5 18.9 18.5 18.9 20.3C18.9 22 20.1 23.1 21.9 23.1C23.7 23.1 25.1 22.1 25.6 20.6",
        1.6,
      ),
  ),
  commandkey: tile(
    "#D139AF",
    stroked("M12.5 12.5V10A2.5 2.5 0 1 0 10 12.5H22A2.5 2.5 0 1 0 19.5 10V22A2.5 2.5 0 1 0 22 19.5H10A2.5 2.5 0 1 0 12.5 22Z", 1.6),
  ),
  database: tile(
    "#D16B39",
    `<ellipse cx="16" cy="9.6" rx="7" ry="2.7" ${STROKE} stroke-width="1.6"/>` +
      stroked(
        "M9 9.6V22.4C9 23.9 12.1 25.2 16 25.2C19.9 25.2 23 23.9 23 22.4V9.6M9 13.9C9 15.4 12.1 16.7 16 16.7C19.9 16.7 23 15.4 23 13.9M9 18.2C9 19.7 12.1 21 16 21C19.9 21 23 19.7 23 18.2",
        1.6,
      ),
  ),
  gear: tile("#3B3B3B", gear()),
  invite: tile("#28A6FF", stroked("M8.6 9.6H23.4C24.3 9.6 25 10.3 25 11.2V21.2C25 22.1 24.3 22.8 23.4 22.8H8.6C7.7 22.8 7 22.1 7 21.2V11.2C7 10.3 7.7 9.6 8.6 9.6ZM7.6 10.6L16 17.2L24.4 10.6", 1.6)),
  package: tile("#D13939", stroked(`${CUBE}M11.7 8.6L20.3 13.4V17.4`, 1.7)),
  string: tile(
    "#39CFD1",
    `<path d="M12.9 10.6C10.9 11.6 9.8 13.5 9.8 15.7C9.8 17.4 10.8 18.6 12.2 18.6C13.5 18.6 14.4 17.7 14.4 16.5C14.4 15.3 13.5 14.4 12.3 14.4L11.8 14.5C12.1 13.2 12.9 12.2 14 11.6ZM20.4 10.6C18.4 11.6 17.3 13.5 17.3 15.7C17.3 17.4 18.3 18.6 19.7 18.6C21 18.6 21.9 17.7 21.9 16.5C21.9 15.3 21 14.4 19.8 14.4L19.3 14.5C19.6 13.2 20.4 12.2 21.5 11.6Z" fill="#fff"/>`,
  ),
  cpu: tile(
    "#66A73D",
    `<rect x="5.6" y="5.6" width="20.8" height="20.8" rx="3.4" fill="#111"/>` +
      `<rect x="8.4" y="8.4" width="15.2" height="15.2" rx="2.2" fill="#EDEDED"/>` +
      `<rect x="8.4" y="19.6" width="15.2" height="4" rx="1.4" fill="#000" fill-opacity=".08"/>`,
  ),
  template: tile("#FFFFFF"),
  symlink: tile(
    "#FFFFFF",
    `<path d="M20.9 10.8C20 8.9 18.3 8 16 8C13.1 8 11.1 9.6 11.1 12C11.1 14.6 13.4 15.3 16 16C18.7 16.7 20.9 17.6 20.9 20.2C20.9 22.6 18.8 24 16 24C13.5 24 11.7 23.1 10.9 21.2" fill="none" stroke="#000" stroke-width="2.8" stroke-linecap="round"/>`,
  ),

  // Package managers and developer tools.
  npm: tile("#CB0000", `<path d="M8 8.4H24V23.6H20V12.4H16V23.6H8Z" fill="#fff"/>`),
  yarn: tile("#2C8EBB", `<circle cx="16" cy="16" r="8.2" ${STROKE} stroke-width="1.6"/>` + stroked("M9.4 11.6C13.6 12.6 18.6 16.4 21.2 22.2M8.2 16.8C11.6 17.4 14.6 19.6 16.2 24M14.2 8C17.6 9.4 21.4 13 23.8 17.6", 1.4)),
  node: tile("#5FA04E", stroked(HEXAGON, 1.8)),
  git: tile("#FF401E", stroked("M12.4 6.6V20.8M12.4 8.4L20 16", 1.9) + dot(12.4, 23.2, 2.5) + dot(21.2, 17.2, 2.5)),
  github: tile(
    "#161614",
    stroked("M10.8 11.6V20.4M21.2 20.4V15.2C21.2 13.1 19.9 11.2 17.2 11.2H14.4M16.4 9L14.2 11.2L16.4 13.4", 1.7) +
      `<circle cx="10.8" cy="9" r="2.3" ${STROKE} stroke-width="1.6"/><circle cx="10.8" cy="23" r="2.3" ${STROKE} stroke-width="1.6"/><circle cx="21.2" cy="23" r="2.3" ${STROKE} stroke-width="1.6"/>`,
  ),
  gitlab: tile(
    "#FC6D26",
    stroked("M11 11.4V20.6M21 11.4V13.4C21 15.6 19.4 17 16 17C13.4 17 11 17.6 11 20.6", 1.7) +
      `<circle cx="11" cy="9" r="2.3" ${STROKE} stroke-width="1.6"/><circle cx="21" cy="9" r="2.3" ${STROKE} stroke-width="1.6"/><circle cx="11" cy="23" r="2.3" ${STROKE} stroke-width="1.6"/>`,
  ),
  commit: tile("#E8743B", stroked("M5.6 16H11.4M20.6 16H26.4", 1.8) + `<circle cx="16" cy="16" r="4.6" ${STROKE} stroke-width="1.8"/>`),
  docker: tile(
    "#2496ED",
    stroked("M7.5 17.5H24.5M9 17.5V12.5H13V17.5M13 17.5V12.5H17V17.5M17 17.5V12.5H21V17.5M13 12.5V7.5H17V12.5M7 17.5C7 21.6 10.4 24.5 15.6 24.5C21 24.5 24.4 21.6 25.2 17.5", 1.5),
  ),
  kubernetes: tile("#326CE5", stroked(HEXAGON, 1.8) + dot(16, 16, 2.6)),
  gradle: tile("#02303A", stroked("M8 12.2L16 8L24 12.2L16 16.4ZM8 16.2L16 20.4L24 16.2M8 20.2L16 24.4L24 20.2", 1.6)),
  heroku: tile("#430098", stroked("M9.5 11.5L14.5 16L9.5 20.5M16.5 22H23", 1.9)),
  netlify: tile("#00AD9F", stroked("M16 6.8L25.2 16L16 25.2L6.8 16Z", 1.7) + dot(16, 16, 2.4)),
  okteto: tile("#1BA9A9", `<circle cx="16" cy="16" r="8.4" ${STROKE} stroke-width="1.7"/><circle cx="16" cy="16" r="3.6" ${STROKE} stroke-width="1.7"/>`),
  firebase: tile("#F4A100", stroked("M16 25.4C11.6 25.4 9 22.6 9 18.9C9 14.6 13 12.9 13.6 6.6C17 8.6 18.4 11.6 18.2 14.8C19.4 14.2 20.2 13 20.4 11.6C22.2 13.4 23 15.8 23 18.4C23 22.4 20.2 25.4 16 25.4Z", 1.6)),

  // Platforms and services.
  android: tile("#3DDC84", stroked("M12.6 6.6H19.4C20.5 6.6 21.4 7.5 21.4 8.6V23.4C21.4 24.5 20.5 25.4 19.4 25.4H12.6C11.5 25.4 10.6 24.5 10.6 23.4V8.6C10.6 7.5 11.5 6.6 12.6 6.6ZM14.6 22.2H17.4", 1.6)),
  apple: tile("#4A4A4A", stroked("M9.2 9H22.8C23.5 9 24 9.5 24 10.2V19.6H8V10.2C8 9.5 8.5 9 9.2 9ZM5.6 22.6H26.4", 1.6)),
  aws: tile("#F29100", stroked(CLOUD, 1.6)),
  azure: tile("#0078D4", stroked(CLOUD, 1.6)),
  gcloud: tile("#4285F4", stroked(CLOUD, 1.6)),
  discord: tile("#5865F2", stroked(BUBBLE, 1.6) + dot(12.4, 14.8, 1.3) + dot(16, 14.8, 1.3) + dot(19.6, 14.8, 1.3)),
  slack: tile("#4A154B", stroked("M13.4 7.6L11.6 24.4M20.4 7.6L18.6 24.4M8.4 12.8H24.4M7.6 19.2H23.6", 1.8)),
  twitter: tile("#1DA1F2", stroked(BUBBLE, 1.6) + stroked("M11.6 14.8H20.4", 1.6)),
  vercel: tile("#000000", stroked("M16 24V8.6M9.6 15L16 8.6L22.4 15", 2)),

  // Bundled fallbacks that are not tiles.
  folder: svg(
    `<path d="M3 7.6C3 6.5 3.9 5.6 5 5.6H11.9C12.5 5.6 13 5.8 13.4 6.3L15.3 8.4H27C28.1 8.4 29 9.3 29 10.4V24.4C29 25.5 28.1 26.4 27 26.4H5C3.9 26.4 3 25.5 3 24.4Z" fill="#2B9BEE"/>`,
  ),
  file: svg(
    `<path d="M8.2 3.5H19.2L25.5 9.8V27C25.5 27.8 24.8 28.5 24 28.5H8.2C7.4 28.5 6.7 27.8 6.7 27V5C6.7 4.2 7.4 3.5 8.2 3.5Z" fill="#fff" stroke="#000" stroke-opacity=".18" stroke-width=".8"/>` +
      `<path d="M19.2 3.5V8.6C19.2 9.3 19.7 9.8 20.4 9.8H25.5Z" fill="#D8D8D8"/>`,
  ),
  /**
   * Stand-in for a Finder folder icon (the app normally serves the real one for `fig://path/…`):
   * the light-blue two-tone folder of macOS.
   */
  "finder-folder": svg(
    `<path d="M2.6 8.4C2.6 7.3 3.5 6.4 4.6 6.4H11.4C12 6.4 12.5 6.6 12.9 7.1L14.4 8.8H27.4C28.5 8.8 29.4 9.7 29.4 10.8V13H2.6Z" fill="#3A9BE3"/>` +
      `<rect x="2.6" y="11" width="26.8" height="15.6" rx="1.7" fill="#6DBAF2"/>` +
      `<rect x="2.6" y="11" width="26.8" height="1.1" rx=".5" fill="#9BD0F7"/>`,
  ),
} as const;

export type AssetName = keyof typeof ICON_ASSETS;

export function isAssetName(name: string): name is AssetName {
  return Object.prototype.hasOwnProperty.call(ICON_ASSETS, name);
}

/** The template tile in any colour (`fig://template?color=…`); white when no colour is given. */
export function templateSvg(color: string | undefined): string {
  return color ? tile(`#${color}`) : ICON_ASSETS.template;
}

export function svgDataUrl(svgDocument: string): string {
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svgDocument)}`;
}
