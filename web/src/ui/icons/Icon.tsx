import { createContext, memo, useContext, useState, type ReactNode } from "react";
import type { Suggestion } from "../../core/contract";
import { ICON_ASSETS, svgDataUrl, templateSvg, type AssetName } from "./assets";
import { resolveIcon, type CornerBadge, type IconContext, type IconSpec } from "./resolve";

export interface IconEnvironment {
  /** The app answers `fig://` image requests. False in a plain browser, where they cannot load. */
  appImages: boolean;
  context: IconContext;
}

export const IconEnvironmentContext = createContext<IconEnvironment>({ appImages: false, context: {} });

const dataUrls = new Map<string, string>();

function cachedDataUrl(key: string, build: () => string): string {
  let url = dataUrls.get(key);
  if (url === undefined) {
    url = svgDataUrl(build());
    dataUrls.set(key, url);
  }
  return url;
}

const assetUrl = (name: AssetName) => cachedDataUrl(`asset:${name}`, () => ICON_ASSETS[name]);
const templateUrl = (color: string | undefined) => cachedDataUrl(`template:${color ?? ""}`, () => templateSvg(color));

function Corner({ badge }: { badge: CornerBadge }) {
  return (
    <span className="figo-icon-badge-corner" style={{ backgroundImage: `url("${templateUrl(badge.color)}")` }}>
      {badge.text}
    </span>
  );
}

/** A square image with an optional badge, like upstream's background-image tile. */
function Tile({ src, size, children, onError }: { src: string; size: number; children?: ReactNode; onError?: () => void }) {
  return (
    <div
      role="img"
      className="figo-icon-image"
      style={{ width: size, height: size, minWidth: size, minHeight: size, fontSize: size * 0.6 }}
    >
      <img src={src} alt="" draggable={false} onError={onError} />
      {children}
    </div>
  );
}

function RemoteImage({ spec, size }: { spec: Extract<IconSpec, { kind: "image" }>; size: number }) {
  const { appImages } = useContext(IconEnvironmentContext);
  const [failedUrl, setFailedUrl] = useState<string | null>(null);

  const unreachable = !appImages && spec.url.startsWith("fig:");
  if (failedUrl === spec.url || unreachable) {
    return spec.fallback ? <IconBody spec={spec.fallback} size={size} /> : null;
  }
  return (
    <Tile src={spec.url} size={size} onError={() => setFailedUrl(spec.url)}>
      {spec.badge && <Corner badge={spec.badge} />}
    </Tile>
  );
}

function IconBody({ spec, size }: { spec: IconSpec; size: number }): ReactNode {
  switch (spec.kind) {
    case "text":
      return (
        <span className="figo-icon-text" style={{ fontSize: size * 0.8 }}>
          {spec.text}
        </span>
      );
    case "asset":
      return <Tile src={assetUrl(spec.name)} size={size}>{spec.badge && <Corner badge={spec.badge} />}</Tile>;
    case "template":
      return (
        <Tile src={templateUrl(spec.color)} size={size}>
          {spec.badge && (
            <span className="figo-icon-badge-center" style={{ fontSize: size * 0.5 }}>
              {spec.badge}
            </span>
          )}
        </Tile>
      );
    case "image":
      return <RemoteImage spec={spec} size={size} />;
  }
}

export const SuggestionIcon = memo(function SuggestionIcon({
  suggestion,
  size,
}: {
  suggestion: Pick<Suggestion, "icon" | "type" | "names">;
  size: number;
}) {
  const { context } = useContext(IconEnvironmentContext);
  const spec = resolveIcon(suggestion, context);
  return (
    <div className="figo-icon" style={{ width: size, height: size, minWidth: size }}>
      <IconBody spec={spec} size={size} />
    </div>
  );
});
