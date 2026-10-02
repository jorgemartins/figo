import type { NativeRequests } from "../bridge/contract";
import { POPOUT_WIDTH } from "./metrics";

export type PositionParams = NativeRequests["window.position"]["params"];
export type PositionResult = NativeRequests["window.position"]["result"];
export type PositionCall = (params: PositionParams) => Promise<PositionResult>;

/** Where the side panel goes. "unknown" until the app has said whether the right side would clip. */
export type DescriptionSide = "unknown" | "left" | "right";

export interface PositionLayout {
  side: DescriptionSide;
  /** The window sits above the caret; the list then hugs the bottom of the window. */
  isAbove: boolean;
}

export interface PositionInput {
  /** Measured size of the page content in CSS px; 0×0 when nothing is rendered. */
  width: number;
  height: number;
  /** The core wants the description in the side panel, and there are suggestions to describe. */
  sidePanel: boolean;
  /**
   * The suggestion list is on screen, so a side panel can be drawn next to it. False for the
   * argument hint box (as upstream) and for the loader (upstream kept the panel offset there,
   * which threw the small loader 200px left of the caret).
   */
  listShown: boolean;
  listWidth: number;
  maxHeight: number;
  /**
   * Changes whenever the caret may have moved (the suggestions were recomputed for a new edit
   * buffer). The side-panel dry run is repeated for each new value.
   */
  revision: unknown;
}

/** Upstream lifts the window 3px towards the caret; the app adds its own 5px gap on top. */
export const OFFSET_FROM_BASELINE = -3;

/**
 * The request that sizes and places the window. A zero size becomes 1, which the app treats as
 * "hide". Sizes are rounded up so the window never clips the last fraction of a pixel of content.
 */
export function frameRequest(input: Pick<PositionInput, "width" | "height" | "listShown">, side: DescriptionSide): PositionParams {
  const width = Math.ceil(input.width);
  const height = Math.ceil(input.height);
  return {
    width: width > 0 ? width : 1,
    height: height > 0 ? height : 1,
    // With the panel on the left the list must stay at the caret, so the window starts a panel's
    // width further left.
    anchorX: side === "left" && input.listShown ? -POPOUT_WIDTH : 0,
    offsetFromBaseline: OFFSET_FROM_BASELINE,
  };
}

/** The dry run that decides the side before the panel is drawn: list plus panel, at full height. */
export function dryRunRequest(listWidth: number, maxHeight: number): PositionParams {
  return {
    width: listWidth + POPOUT_WIDTH,
    height: maxHeight,
    anchorX: 0,
    offsetFromBaseline: 0,
    dryRun: true,
  };
}

export function layoutFromResult(result: PositionResult): PositionLayout {
  return { side: result.isClipped ? "left" : "right", isAbove: result.isAbove };
}

function sameFrame(a: PositionParams | null, b: PositionParams): boolean {
  return (
    a !== null &&
    a.width === b.width &&
    a.height === b.height &&
    a.anchorX === b.anchorX &&
    a.offsetFromBaseline === b.offsetFromBaseline
  );
}

/**
 * Keeps the native window in step with the page. The owner calls `update` after every render and
 * resize with freshly measured sizes; each new size or anchor is sent as a `window.position`
 * request. While the side panel is wanted, a dry run first decides whether it goes left or right,
 * and every answer refreshes that decision and the above/below flag. Outside side-panel mode the
 * answers are ignored, as upstream does.
 */
export class PositionController {
  private layout: PositionLayout = { side: "unknown", isAbove: false };
  private input: PositionInput | null = null;
  private lastFrame: PositionParams | null = null;
  private dryRunToken = 0;
  private disposed = false;

  constructor(
    private readonly call: PositionCall,
    private readonly onLayout: (layout: PositionLayout) => void,
    private readonly onError: (error: unknown) => void = () => {},
  ) {}

  getLayout(): PositionLayout {
    return this.layout;
  }

  update(input: PositionInput): void {
    if (this.disposed) {
      return;
    }
    const previous = this.input;
    this.input = input;

    const panelChanged =
      !previous ||
      previous.sidePanel !== input.sidePanel ||
      previous.listWidth !== input.listWidth ||
      previous.maxHeight !== input.maxHeight;

    if (panelChanged && previous) {
      // Until the dry run answers, the description stays in the footer. Leaving panel mode also
      // drops the above flag, since it only matters next to the panel.
      this.setLayout({
        side: "unknown",
        isAbove: input.sidePanel ? this.layout.isAbove : false,
      });
    }

    if (input.sidePanel && (panelChanged || previous?.revision !== input.revision)) {
      this.runDryRun(input);
    }

    this.sendFrame();
  }

  dispose(): void {
    this.disposed = true;
  }

  private runDryRun(input: PositionInput): void {
    const token = ++this.dryRunToken;
    this.call(dryRunRequest(input.listWidth, input.maxHeight)).then(
      (result) => {
        // Only the latest dry run counts, and only while the panel is still wanted.
        if (!this.disposed && token === this.dryRunToken && this.input?.sidePanel) {
          this.setLayout(layoutFromResult(result));
        }
      },
      (error: unknown) => this.onError(error),
    );
  }

  private sendFrame(): void {
    const input = this.input;
    if (!input) {
      return;
    }
    const frame = frameRequest(input, this.layout.side);
    if (sameFrame(this.lastFrame, frame)) {
      return;
    }
    this.lastFrame = frame;
    this.call(frame).then(
      (result) => {
        if (!this.disposed && this.input?.sidePanel) {
          this.setLayout(layoutFromResult(result));
        }
      },
      (error: unknown) => {
        // A refused request (a command is running, say) must be retried with the next update.
        if (this.lastFrame === frame) {
          this.lastFrame = null;
        }
        this.onError(error);
      },
    );
  }

  private setLayout(layout: PositionLayout): void {
    if (layout.side === this.layout.side && layout.isAbove === this.layout.isAbove) {
      return;
    }
    // No frame is sent from here: the new side changes the page, and the next `update` carries
    // both the new anchor and the size measured after that change. Sending now would briefly
    // place the old content at the new anchor.
    this.layout = layout;
    this.onLayout(layout);
  }
}
