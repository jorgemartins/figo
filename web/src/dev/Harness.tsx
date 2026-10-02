import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import type { ActionId } from "../core/contract";
import { Popup } from "../ui/Popup";
import type { PositionCall, PositionParams, PositionResult } from "../ui/position";
import type { ThemeLoader } from "../ui/theme/theme";
import { FakeCore } from "./fakeCore";
import { HARBOR_THEME, HARBOR_THEME_NAME, SCENARIOS, type Prompt, type Scenario, type TerminalLine } from "./scenarios";
import "./harness.css";

/**
 * Terminals report the IME caret a few points right of the cursor cell (measured: the list sits
 * 6pt right of the cell's left edge, of which 3.2 is the popup's own padding).
 */
const CARET_X_OFFSET = 2.8;
/** The app's own gap between the caret and the window, added to offsetFromBaseline. */
const NATIVE_GAP = 5;

interface Frame {
  x: number;
  y: number;
  width: number;
  height: number;
  hidden: boolean;
}

const HIDDEN: Frame = { x: 0, y: 0, width: 0, height: 0, hidden: true };

function actionFor(event: KeyboardEvent): ActionId | null {
  if (event.ctrlKey && !event.metaKey && !event.altKey) {
    switch (event.key.toLowerCase()) {
      case "k":
        return "toggleDescription";
      case "p":
        return "navigateUp";
      case "n":
        return "navigateDown";
      case "r":
        return "toggleHistoryMode";
      case "=":
      case "+":
        return "increaseSize";
      case "-":
        return "decreaseSize";
      default:
        return null;
    }
  }
  if (event.metaKey || event.altKey || event.ctrlKey) {
    return null;
  }
  switch (event.key) {
    case "ArrowUp":
      return "navigateUp";
    case "ArrowDown":
      return "navigateDown";
    case "Enter":
      return "insertSelected";
    case "Tab":
      return event.shiftKey ? "navigateUp" : "insertCommonPrefix";
    case "Escape":
      return "hideAutocomplete";
    default:
      return null;
  }
}

function PromptView({ prompt }: { prompt: Prompt }) {
  if (prompt.kind === "home") {
    return (
      <>
        <span className="seg seg-blue"> ~ </span>
        <span className="tip tip-blue" />
      </>
    );
  }
  return (
    <>
      <span className="seg seg-blue"> {prompt.path} </span>
      <span className="tip tip-blue-green" />
      <span className="seg seg-green"> ⎇ {prompt.branch} </span>
      <span className="tip tip-green" />
    </>
  );
}

function LineView({ line }: { line: TerminalLine }) {
  if (typeof line === "string") {
    return <div className="term-line">{line}</div>;
  }
  if ("prompt" in line) {
    return (
      <div className="term-line">
        <PromptView prompt={line.prompt} /> {line.command}
      </div>
    );
  }
  return (
    <div className="term-line">
      {line.parts.map((part, index) => (
        <span key={index} className={part.tone ? `tone-${part.tone}` : undefined}>
          {part.text}
        </span>
      ))}
    </div>
  );
}

const SCENARIO_THEME = "(scenario)";
const THEME_CHOICES = [SCENARIO_THEME, "dark", "light", "system", HARBOR_THEME_NAME];

/** Lists the themes in FIGO_THEMES_DIR when the dev server was started with it. */
function useDevThemes(): string[] {
  const [names, setNames] = useState<string[]>([]);
  useEffect(() => {
    fetch("/__themes/index.json")
      .then((response) => (response.ok ? (response.json() as Promise<string[]>) : []))
      .then(setNames, () => setNames([]));
  }, []);
  return names;
}

const loadTheme: ThemeLoader = async (name) => {
  if (name === HARBOR_THEME_NAME) {
    return HARBOR_THEME;
  }
  const response = await fetch(`/__themes/${encodeURIComponent(name)}.json`);
  if (!response.ok) {
    throw new Error(`No theme ${name}`);
  }
  return (await response.json()) as unknown;
};

function initialScenario(): Scenario {
  const id = new URLSearchParams(location.search).get("scenario");
  return SCENARIOS.find((scenario) => scenario.id === id) ?? SCENARIOS[0]!;
}

export function Harness() {
  const [scenario, setScenario] = useState<Scenario>(initialScenario);
  const [themeOverride, setThemeOverride] = useState(
    () => new URLSearchParams(location.search).get("theme") ?? SCENARIO_THEME,
  );
  const devThemes = useDevThemes();

  const navigate = useCallback((id: string) => {
    const next = SCENARIOS.find((candidate) => candidate.id === id);
    if (next) {
      setScenario(next);
    }
  }, []);

  const core = useMemo(() => new FakeCore(scenario, navigate), [scenario, navigate]);
  useEffect(() => () => core.dispose(), [core]);

  useEffect(() => {
    const params = new URLSearchParams(location.search);
    params.set("scenario", scenario.id);
    if (themeOverride === SCENARIO_THEME) {
      params.delete("theme");
    } else {
      params.set("theme", themeOverride);
    }
    history.replaceState(null, "", `?${params.toString()}`);
  }, [scenario, themeOverride]);

  useLayoutEffect(() => {
    core.setThemeOverride(themeOverride === SCENARIO_THEME ? null : themeOverride);
  }, [core, themeOverride]);

  const state = useSyncExternalStore(
    (listener) => core.subscribe(() => listener()),
    () => core.getState(),
  );
  const line = core.getLine();

  // The fake app: places the popup "window" against the caret the way the native side does.
  const screenRef = useRef<HTMLDivElement>(null);
  const caretRef = useRef<HTMLSpanElement>(null);
  const lastFrame = useRef<PositionParams | null>(null);
  const [frame, setFrame] = useState<Frame>(HIDDEN);
  const [requests, setRequests] = useState<PositionParams[]>([]);
  const heightSetting = state.settings["autocomplete.height"];
  const heightRef = useRef(140);
  heightRef.current = typeof heightSetting === "number" ? heightSetting : 140;

  const place = useCallback((params: PositionParams, apply: boolean): PositionResult => {
    const screen = screenRef.current?.getBoundingClientRect();
    const cell = caretRef.current?.getBoundingClientRect();
    if (!screen || !cell) {
      return { isAbove: false, isClipped: false };
    }
    const caret = { x: cell.left - screen.left + CARET_X_OFFSET, y: cell.top - screen.top, h: cell.height };
    const anchorY = params.offsetFromBaseline + NATIVE_GAP;
    const { width, height } = params;
    const overflowsBelow = caret.y + caret.h + anchorY + height > screen.height;
    const overflowsAbove = caret.y - height - anchorY < 0;
    // As upstream: the decision uses the height setting, not the real window height.
    const isAbove = !overflowsAbove && (overflowsBelow || screen.height < caret.y + caret.h + heightRef.current);
    const isClipped = caret.x + width > screen.width;
    if (apply) {
      const x = Math.max(0, Math.min(caret.x + params.anchorX, screen.width - width));
      const top = isAbove ? caret.y - height - anchorY : caret.y + caret.h + anchorY;
      const y = Math.max(0, Math.min(top, screen.height - height));
      setFrame(width <= 1 || height <= 1 ? HIDDEN : { x, y, width, height, hidden: false });
    }
    return { isAbove, isClipped };
  }, []);

  const position = useCallback<PositionCall>(
    async (params) => {
      setRequests((previous) => [params, ...previous].slice(0, 8));
      if (!params.dryRun) {
        lastFrame.current = params;
      }
      return place(params, !params.dryRun);
    },
    [place],
  );

  // Like the app, re-place the window at the last requested size whenever the caret moves.
  useLayoutEffect(() => {
    if (lastFrame.current) {
      place(lastFrame.current, true);
    }
  }, [line, scenario, place]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.target instanceof HTMLSelectElement) {
        return;
      }
      const current = core.getState();
      // Bound keys are only taken from the shell while the popup shows suggestions.
      const intercepting = current.visible && current.suggestions.length > 0;
      const action = actionFor(event);
      if (action && intercepting) {
        event.preventDefault();
        core.dispatch(action);
        return;
      }
      if (event.key === "Enter" && !event.metaKey && !event.ctrlKey) {
        event.preventDefault();
        core.run();
      } else if (event.key === "Backspace") {
        event.preventDefault();
        core.backspace();
      } else if (event.key === "Tab") {
        event.preventDefault();
      } else if (event.key.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey) {
        event.preventDefault();
        core.type(event.key);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [core]);

  const pad = " ".repeat(scenario.indent ?? 0);

  return (
    <div className="harness">
      <aside className="harness-side">
        <h1>Figo popup</h1>
        <p className="harness-help">
          ↑ ↓ ⇧⇥ ⌃P ⌃N move · ⏎ insert · ⇥ common prefix (shakes when there is none) · ⎋ hide · ⌃K side panel ·
          ⌃R history · ⌃= ⌃- size · type to filter, ⌫ to delete, ⏎ while hidden runs the line.
        </p>
        <nav className="harness-scenarios">
          {SCENARIOS.map((candidate) => (
            <button
              key={candidate.id}
              type="button"
              className={candidate.id === scenario.id ? "is-current" : undefined}
              onClick={(event) => {
                event.currentTarget.blur();
                setScenario(candidate);
              }}
            >
              {candidate.label}
            </button>
          ))}
        </nav>
        <p className="harness-note">{scenario.note}</p>
        <label className="harness-theme">
          Theme{" "}
          <select value={themeOverride} onChange={(event) => setThemeOverride(event.target.value)}>
            {[...THEME_CHOICES, ...devThemes].map((name) => (
              <option key={name} value={name}>
                {name}
              </option>
            ))}
          </select>
        </label>
        <div className="harness-requests">
          <div>window.position, newest first</div>
          {requests.map((request, index) => (
            <code key={index}>
              {request.dryRun ? "dry run " : ""}
              {request.width}×{request.height} anchorX {request.anchorX} offset {request.offsetFromBaseline}
            </code>
          ))}
        </div>
      </aside>
      <main className="harness-stage">
        <div className="desktop">
          <div className="terminal" ref={screenRef}>
            <div className="traffic">
              <i className="red" />
              <i className="yellow" />
              <i className="green" />
            </div>
            <div className="term-body">
              {scenario.preamble.map((preambleLine, index) => (
                <LineView key={index} line={preambleLine} />
              ))}
              {Array.from({ length: scenario.pushDown ?? 0 }, (_, index) => (
                <div key={`blank-${index}`} className="term-line">
                  {" "}
                </div>
              ))}
              {core.output.map((ran, index) => (
                <div key={`ran-${index}`} className="term-line">
                  <PromptView prompt={scenario.prompt} /> {ran}
                </div>
              ))}
              <div className="term-line">
                {pad}
                <PromptView prompt={scenario.prompt} /> {line}
                <span ref={caretRef} className="caret">
                  {" "}
                </span>
              </div>
            </div>
            <div
              className="popup-window"
              style={
                frame.hidden
                  ? { visibility: "hidden" }
                  : { left: frame.x, top: frame.y, width: frame.width, height: frame.height }
              }
            >
              <Popup core={core} position={position} loadTheme={loadTheme} />
            </div>
          </div>
        </div>
      </main>
    </div>
  );
}
