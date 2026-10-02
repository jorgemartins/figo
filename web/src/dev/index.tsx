import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { Harness } from "./Harness";

/** Renders the dev harness: the real popup against a fake core over a mock terminal. */
export function mountHarness(container: HTMLElement): void {
  document.title = "Figo popup · dev harness";
  createRoot(container).render(
    <StrictMode>
      <Harness />
    </StrictMode>,
  );
}
