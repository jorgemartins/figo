import { describe, expect, it, vi } from "vitest";
import {
  dryRunRequest,
  frameRequest,
  layoutFromResult,
  PositionController,
  type PositionInput,
  type PositionLayout,
  type PositionParams,
  type PositionResult,
} from "./position";

describe("frameRequest", () => {
  it("sends the measured size, rounded up, 3px towards the caret", () => {
    expect(frameRequest({ width: 326.4, height: 146.4, listShown: true }, "unknown")).toEqual({
      width: 327,
      height: 147,
      anchorX: 0,
      offsetFromBaseline: -3,
    });
  });

  it("sizes an empty page to 1×1, which hides the window", () => {
    expect(frameRequest({ width: 0, height: 0, listShown: true }, "unknown")).toMatchObject({ width: 1, height: 1 });
  });

  it("shifts the window 200px left only when the panel is drawn on the left", () => {
    expect(frameRequest({ width: 531.2, height: 146.4, listShown: true }, "left").anchorX).toBe(-200);
    expect(frameRequest({ width: 531.2, height: 146.4, listShown: true }, "right").anchorX).toBe(0);
    // The argument hint box and the loader are drawn without the panel.
    expect(frameRequest({ width: 200, height: 46.4, listShown: false }, "left").anchorX).toBe(0);
  });
});

describe("dryRunRequest", () => {
  it("asks about list plus panel at full height without moving anything", () => {
    expect(dryRunRequest(320, 140)).toEqual({ width: 520, height: 140, anchorX: 0, offsetFromBaseline: 0, dryRun: true });
  });
});

describe("layoutFromResult", () => {
  it("puts the panel left when the right side would clip", () => {
    expect(layoutFromResult({ isAbove: false, isClipped: true })).toEqual({ side: "left", isAbove: false });
    expect(layoutFromResult({ isAbove: true, isClipped: false })).toEqual({ side: "right", isAbove: true });
  });
});

type Pending = { params: PositionParams; resolve: (result: PositionResult) => void; reject: (error: unknown) => void };

function setup() {
  const calls: Pending[] = [];
  const call = vi.fn(
    (params: PositionParams) =>
      new Promise<PositionResult>((resolve, reject) => {
        calls.push({ params, resolve, reject });
      }),
  );
  const layouts: PositionLayout[] = [];
  const errors: unknown[] = [];
  const controller = new PositionController(call, (layout) => layouts.push(layout), (error) => errors.push(error));
  const base: PositionInput = {
    width: 326.4,
    height: 146.4,
    sidePanel: false,
    listShown: true,
    listWidth: 320,
    maxHeight: 140,
    revision: 1,
  };
  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
  return { calls, call, layouts, errors, controller, base, flush };
}

describe("PositionController", () => {
  it("sends a frame for each new size, and only then", () => {
    const { calls, controller, base } = setup();
    controller.update(base);
    controller.update(base);
    controller.update({ ...base, revision: 2 });
    expect(calls.map((c) => c.params)).toEqual([{ width: 327, height: 147, anchorX: 0, offsetFromBaseline: -3 }]);
    controller.update({ ...base, width: 0, height: 0 });
    expect(calls[1]?.params).toMatchObject({ width: 1, height: 1 });
  });

  it("ignores answers outside side-panel mode", async () => {
    const { calls, controller, base, layouts, flush } = setup();
    controller.update(base);
    calls[0]?.resolve({ isAbove: true, isClipped: true });
    await flush();
    expect(layouts).toEqual([]);
    expect(controller.getLayout()).toEqual({ side: "unknown", isAbove: false });
  });

  it("runs a dry run when the panel is wanted, then sends the anchor it decided", async () => {
    const { calls, controller, base, layouts, flush } = setup();
    controller.update(base);
    controller.update({ ...base, sidePanel: true });
    expect(calls.map((c) => c.params.dryRun ?? false)).toEqual([false, true]);
    expect(calls[1]?.params).toEqual({ width: 520, height: 140, anchorX: 0, offsetFromBaseline: 0, dryRun: true });

    calls[1]?.resolve({ isAbove: false, isClipped: true });
    await flush();
    expect(layouts.at(-1)).toEqual({ side: "left", isAbove: false });

    // The page now shows the panel on the left; the owner reports the new size.
    controller.update({ ...base, sidePanel: true, width: 531.2 });
    expect(calls.at(-1)?.params).toEqual({ width: 532, height: 147, anchorX: -200, offsetFromBaseline: -3 });
  });

  it("re-runs the dry run for every new revision while the panel is wanted", () => {
    const { calls, controller, base } = setup();
    controller.update({ ...base, sidePanel: true });
    controller.update({ ...base, sidePanel: true });
    controller.update({ ...base, sidePanel: true, revision: 2 });
    expect(calls.filter((c) => c.params.dryRun)).toHaveLength(2);
  });

  it("keeps only the latest dry run's answer", async () => {
    const { calls, controller, base, flush } = setup();
    controller.update({ ...base, sidePanel: true });
    controller.update({ ...base, sidePanel: true, revision: 2 });
    const [first, second] = calls.filter((c) => c.params.dryRun);
    second?.resolve({ isAbove: false, isClipped: false });
    first?.resolve({ isAbove: true, isClipped: true });
    await flush();
    expect(controller.getLayout()).toEqual({ side: "right", isAbove: false });
  });

  it("takes the side and above flag from frame answers while the panel is wanted", async () => {
    const { calls, controller, base, flush } = setup();
    controller.update({ ...base, sidePanel: true });
    const frame = calls.find((c) => !c.params.dryRun);
    frame?.resolve({ isAbove: true, isClipped: false });
    await flush();
    expect(controller.getLayout()).toEqual({ side: "right", isAbove: true });
  });

  it("returns the description to the footer when the panel is turned off", async () => {
    const { calls, controller, base, layouts, flush } = setup();
    controller.update({ ...base, sidePanel: true });
    calls.find((c) => c.params.dryRun)?.resolve({ isAbove: true, isClipped: false });
    await flush();
    controller.update({ ...base, sidePanel: false });
    expect(layouts.at(-1)).toEqual({ side: "unknown", isAbove: false });
  });

  it("starts over with an unknown side when the list size changes", async () => {
    const { calls, controller, base, flush } = setup();
    controller.update({ ...base, sidePanel: true });
    calls.find((c) => c.params.dryRun)?.resolve({ isAbove: false, isClipped: true });
    await flush();
    controller.update({ ...base, sidePanel: true, listWidth: 352 });
    expect(controller.getLayout().side).toBe("unknown");
    expect(calls.filter((c) => c.params.dryRun).at(-1)?.params).toMatchObject({ width: 552 });
  });

  it("retries a refused frame with the next update and reports the error", async () => {
    const { calls, controller, base, errors, flush } = setup();
    controller.update(base);
    calls[0]?.reject(new Error("Cannot position autocomplete window while preexec is active"));
    await flush();
    expect(errors).toHaveLength(1);
    controller.update(base);
    expect(calls).toHaveLength(2);
  });

  it("does nothing after dispose", async () => {
    const { calls, controller, base, layouts, flush } = setup();
    controller.update({ ...base, sidePanel: true });
    controller.dispose();
    calls.forEach((c) => c.resolve({ isAbove: true, isClipped: true }));
    await flush();
    controller.update({ ...base, width: 10 });
    expect(layouts).toEqual([]);
    expect(calls).toHaveLength(2);
  });
});
