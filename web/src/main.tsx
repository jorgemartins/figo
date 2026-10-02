import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createNativeBridge, hasNativeHost } from "./bridge/native";
import { createCore } from "./core";
import { Popup } from "./ui/Popup";
import type { PositionCall } from "./ui/position";
import "./ui/page.css";

const container = document.getElementById("root")!;

if (hasNativeHost()) {
  document.documentElement.classList.add("figo-page");
  const bridge = createNativeBridge();
  const core = createCore(bridge, { storage: localStorage });
  const position: PositionCall = (params) => bridge.call("window.position", params);

  // What the popup is showing, for `figo status` and automated tests. Not used for behaviour.
  let lastReport = "";
  core.subscribe((state) => {
    const selected = state.suggestions[state.selectedIndex];
    const report = {
      visible: state.visible,
      loading: state.loading,
      count: state.suggestions.length,
      selectedIndex: state.selectedIndex,
      selected: selected ? (selected.displayName ?? selected.names.join(", ")) : null,
      first: state.suggestions.slice(0, 12).map((item) => ({
        name: item.displayName ?? item.names.join(", "),
        type: item.type,
        description: item.description ?? null,
      })),
      argument: state.argument?.name ?? null,
    };
    const serialised = JSON.stringify(report);
    if (serialised === lastReport) return;
    lastReport = serialised;
    void bridge.call("app.reportState", { state: report }).catch(() => {});
  });
  const logError = (error: unknown) => {
    const message = error instanceof Error ? error.message : String(error);
    void bridge.call("app.log", { level: "debug", message: `window.position: ${message}` }).catch(() => {});
  };

  createRoot(container).render(
    <StrictMode>
      <Popup core={core} position={position} appImages onError={logError} />
    </StrictMode>,
  );
} else {
  // A plain browser (`pnpm dev`): show the popup against a fake core over a mock terminal.
  void import("./dev").then(({ mountHarness }) => mountHarness(container));
}
