import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import type { Core, CoreState } from "../core/contract";
import { ArgumentHintBox, DescriptionFooter, DescriptionPanel } from "./Description";
import { descriptionHint } from "./hint";
import { useCoreState, useShake, useThemeColors } from "./hooks";
import { IconEnvironmentContext, type IconEnvironment } from "./icons/Icon";
import { Loading } from "./Loading";
import { alwaysShowDescription, computeMetrics, fontFamilySetting, themeSetting, type Metrics } from "./metrics";
import { PositionController, type PositionCall, type PositionLayout } from "./position";
import { Row } from "./Row";
import { fetchThemeFile, themeVariables, type ThemeLoader } from "./theme/theme";
import { prefixUnderline } from "./title";
import { VirtualList } from "./VirtualList";
import { viewportHeight } from "./windowing";
import "./popup.css";

export interface PopupProps {
  core: Core;
  /** Sends `window.position` to the app. Without it the popup only renders. */
  position?: PositionCall;
  /** Reads a theme file by name; defaults to `figo://themes/<name>.json`. */
  loadTheme?: ThemeLoader;
  /** Whether `fig://` image URLs can be loaded (only inside the app). */
  appImages?: boolean;
  /** Called with errors from the app that the popup can do nothing about, for logging. */
  onError?: (error: unknown) => void;
}

type Content = "nothing" | "loading" | "list" | "argument";

function contentKind(state: CoreState): Content {
  if (!state.visible) {
    return "nothing";
  }
  if (state.loading) {
    return "loading";
  }
  if (state.suggestions.length > 0) {
    return "list";
  }
  return state.argument?.name.trim() ? "argument" : "nothing";
}

function rootStyle(metrics: Metrics, fontFamily: string | undefined, theme: Record<string, string>): CSSProperties {
  const style: Record<string, string> = { ...theme, "--rem": `${metrics.fontSize}px` };
  if (fontFamily) {
    style["--font-family"] = fontFamily;
  }
  return style as CSSProperties;
}

function SuggestionList({
  state,
  metrics,
  layout,
  shaking,
  onInsert,
}: {
  state: CoreState;
  metrics: Metrics;
  layout: PositionLayout;
  shaking: boolean;
  onInsert: (index: number) => void;
}) {
  const { suggestions, selectedIndex, commonPrefix, settings } = state;
  const selected = suggestions[selectedIndex];
  const hint = useMemo(() => (alwaysShowDescription(settings) ? null : descriptionHint(settings)), [settings]);
  // Kept stable across unrelated state changes so the memoised rows do not all re-render.
  const underline = useMemo(
    () => prefixUnderline({ suggestions, selectedIndex, commonPrefix }),
    [suggestions, selectedIndex, commonPrefix],
  );
  // Until the app has said which side has room, the description stays in the footer.
  const side = state.descriptionPopout ? layout.side : "unknown";
  const hasFooter = side === "unknown";

  const listHeight = viewportHeight(
    suggestions.length,
    metrics.itemSize,
    metrics.maxHeight - (hasFooter ? metrics.itemSize : 0),
  );
  const listClass = ["figo-list", hasFooter && "has-footer", shaking && "is-shaking"].filter(Boolean).join(" ");

  const panel = side !== "unknown" && <DescriptionPanel selected={selected} hint={hint} maxHeight={metrics.panelMaxHeight} />;

  return (
    <div className="figo-frame">
      {side === "left" && panel}
      <div
        className="figo-list-container"
        style={{
          width: metrics.listWidth,
          maxHeight: metrics.maxHeight,
          alignSelf: layout.isAbove ? "flex-end" : "flex-start",
        }}
      >
        <VirtualList
          className={listClass}
          count={suggestions.length}
          itemSize={metrics.itemSize}
          height={listHeight}
          selectedIndex={selectedIndex}
          revision={suggestions}
          renderRow={(index, top) => {
            const suggestion = suggestions[index];
            return (
              suggestion && (
                <Row
                  key={index}
                  suggestion={suggestion}
                  index={index}
                  selected={index === selectedIndex}
                  top={top}
                  itemSize={metrics.itemSize}
                  iconSize={metrics.iconSize}
                  underline={underline}
                  onInsert={onInsert}
                />
              )
            );
          }}
        />
        {hasFooter && (
          <DescriptionFooter selected={selected} argument={state.argument} hint={hint} itemSize={metrics.itemSize} />
        )}
      </div>
      {side === "right" && panel}
    </div>
  );
}

/**
 * The autocomplete popup: renders the core's state and keeps the native window sized to it.
 * Behaviour (selection, keys, insertion, visibility) lives in the core; this owns only layout.
 */
export function Popup({ core, position, loadTheme = fetchThemeFile, appImages = false, onError }: PopupProps) {
  const state = useCoreState(core);
  const { settings } = state;
  const metrics = useMemo(
    () => computeMetrics(settings, state.scale, state.historyMode),
    [settings, state.scale, state.historyMode],
  );
  const colors = useThemeColors(themeSetting(settings), loadTheme);
  const theme = useMemo(() => themeVariables(colors), [colors]);
  const fontFamily = fontFamilySetting(settings);
  const shaking = useShake(state.shakeCount);
  const onInsert = useCallback((index: number) => core.insert(index), [core]);
  const iconEnvironment = useMemo<IconEnvironment>(() => ({ appImages, context: {} }), [appImages]);

  const [layout, setLayout] = useState<PositionLayout>({ side: "unknown", isAbove: false });
  const rootRef = useRef<HTMLDivElement>(null);
  const controllerRef = useRef<PositionController | null>(null);
  const kind = contentKind(state);

  const onErrorRef = useRef(onError);
  onErrorRef.current = onError;

  // A layout effect, so the controller exists before the first measurement below.
  useLayoutEffect(() => {
    if (!position) {
      return;
    }
    const controller = new PositionController(position, setLayout, (error) => onErrorRef.current?.(error));
    controllerRef.current = controller;
    return () => {
      controller.dispose();
      controllerRef.current = null;
    };
  }, [position]);

  const latest = useRef({ state, metrics, kind });
  latest.current = { state, metrics, kind };

  // Measures the page and tells the app; also used by the ResizeObserver for size changes that
  // do not come from a render (fonts and images finishing loading).
  const publish = useCallback(() => {
    const root = rootRef.current;
    const controller = controllerRef.current;
    if (!root || !controller) {
      return;
    }
    const { state: current, metrics: currentMetrics, kind: currentKind } = latest.current;
    const rect = root.getBoundingClientRect();
    controller.update({
      width: rect.width,
      height: rect.height,
      sidePanel: current.descriptionPopout,
      listShown: currentKind === "list",
      listWidth: currentMetrics.listWidth,
      maxHeight: currentMetrics.maxHeight,
      revision: current.suggestions,
    });
  }, []);

  useLayoutEffect(publish);

  useEffect(() => {
    const root = rootRef.current;
    if (!root || typeof ResizeObserver === "undefined") {
      return;
    }
    const observer = new ResizeObserver(() => publish());
    observer.observe(root);
    return () => observer.disconnect();
  }, [publish]);

  let content = null;
  if (kind === "loading") {
    content = <Loading />;
  } else if (kind === "list") {
    content = <SuggestionList state={state} metrics={metrics} layout={layout} shaking={shaking} onInsert={onInsert} />;
  } else if (kind === "argument" && state.argument) {
    content = (
      <div className="figo-frame">
        <ArgumentHintBox argument={state.argument} itemSize={metrics.itemSize} />
      </div>
    );
  }

  return (
    <IconEnvironmentContext.Provider value={iconEnvironment}>
      <div ref={rootRef} className="figo-popup" style={rootStyle(metrics, fontFamily, theme)}>
        {content}
      </div>
    </IconEnvironmentContext.Provider>
  );
}
