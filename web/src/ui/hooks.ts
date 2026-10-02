import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import type { Core, CoreState } from "../core/contract";
import { builtInTheme, DARK_THEME, loadTheme, type ThemeColors, type ThemeLoader } from "./theme/theme";

export function useCoreState(core: Core): CoreState {
  const snapshot = () => core.getState();
  // The third argument lets tests render the popup to static markup.
  return useSyncExternalStore((listener) => core.subscribe(() => listener()), snapshot, snapshot);
}

/** Upstream plays 200ms of a 0.5s jitter, so only part of one cycle is ever seen. */
const SHAKE_MS = 200;

/** True for 200ms after each increment of the core's shake counter (but not on first render). */
export function useShake(shakeCount: number): boolean {
  const seen = useRef(shakeCount);
  const [shaking, setShaking] = useState(false);
  useEffect(() => {
    if (shakeCount === seen.current) {
      return;
    }
    seen.current = shakeCount;
    setShaking(true);
    const timer = setTimeout(() => setShaking(false), SHAKE_MS);
    return () => clearTimeout(timer);
  }, [shakeCount]);
  return shaking;
}

const DARK_QUERY = "(prefers-color-scheme: dark)";

function systemIsDark(): boolean {
  return typeof window !== "undefined" && typeof window.matchMedia === "function"
    ? window.matchMedia(DARK_QUERY).matches
    : true;
}

/** Follows the system appearance, for the "system" theme. */
export function useSystemIsDark(): boolean {
  const [dark, setDark] = useState(systemIsDark);
  useEffect(() => {
    if (typeof window.matchMedia !== "function") {
      return;
    }
    const query = window.matchMedia(DARK_QUERY);
    const listener = (event: MediaQueryListEvent) => setDark(event.matches);
    query.addEventListener("change", listener);
    setDark(query.matches);
    return () => query.removeEventListener("change", listener);
  }, []);
  return dark;
}

/**
 * The colours for `autocomplete.theme`. Built-ins resolve synchronously; while a theme file loads
 * the previous colours stay, so switching themes never flashes the dark default.
 */
export function useThemeColors(setting: string | undefined, loader: ThemeLoader): ThemeColors {
  const systemDark = useSystemIsDark();
  const builtIn = builtInTheme(setting, systemDark);
  const [loaded, setLoaded] = useState<{ name: string; colors: ThemeColors } | null>(null);
  const last = useRef<ThemeColors>(builtIn ?? DARK_THEME);

  useEffect(() => {
    if (builtIn || setting === undefined) {
      return;
    }
    let cancelled = false;
    void loadTheme(setting, systemDark, loader).then((colors) => {
      if (!cancelled) {
        setLoaded({ name: setting, colors });
      }
    });
    return () => {
      cancelled = true;
    };
  }, [setting, builtIn, systemDark, loader]);

  const colors = builtIn ?? (loaded && loaded.name === setting ? loaded.colors : last.current);
  last.current = colors;
  return colors;
}
