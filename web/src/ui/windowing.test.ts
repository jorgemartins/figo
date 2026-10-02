import { describe, expect, it } from "vitest";
import { smartScrollOffset, viewportHeight, visibleRange } from "./windowing";

describe("viewportHeight", () => {
  it("is the rows' height, capped by the space available", () => {
    expect(viewportHeight(3, 20, 120)).toBe(60);
    expect(viewportHeight(13, 20, 120)).toBe(120);
    expect(viewportHeight(13, 20, 140)).toBe(140);
    expect(viewportHeight(0, 20, 120)).toBe(0);
  });
});

describe("visibleRange", () => {
  it("renders the visible rows plus the overscan", () => {
    expect(visibleRange(0, 120, 20, 50)).toEqual([0, 8]);
    expect(visibleRange(200, 120, 20, 50)).toEqual([8, 18]);
    expect(visibleRange(210, 120, 20, 50)).toEqual([8, 19]);
  });

  it("stays inside the list", () => {
    expect(visibleRange(0, 120, 20, 3)).toEqual([0, 3]);
    expect(visibleRange(880, 120, 20, 50)).toEqual([42, 50]);
    expect(visibleRange(0, 120, 20, 0)).toEqual([0, 0]);
  });
});

describe("smartScrollOffset (react-window's smart alignment)", () => {
  const viewport = 120;
  const item = 20;
  const count = 30;

  it("does not move when the row is fully visible", () => {
    expect(smartScrollOffset(0, 0, viewport, item, count)).toBe(0);
    expect(smartScrollOffset(5, 0, viewport, item, count)).toBe(0);
    expect(smartScrollOffset(8, 60, viewport, item, count)).toBe(60);
  });

  it("scrolls minimally to a row just outside the viewport", () => {
    // Down past the last visible row: that row ends up at the bottom.
    expect(smartScrollOffset(6, 0, viewport, item, count)).toBe(20);
    expect(smartScrollOffset(9, 60, viewport, item, count)).toBe(80);
    // Up past the first visible row: that row ends up at the top.
    expect(smartScrollOffset(2, 60, viewport, item, count)).toBe(40);
  });

  it("centres a row that is far away", () => {
    expect(smartScrollOffset(20, 0, viewport, item, count)).toBe(350);
    expect(smartScrollOffset(15, 480, viewport, item, count)).toBe(250);
  });

  it("clamps to the ends", () => {
    expect(smartScrollOffset(29, 0, viewport, item, count)).toBe(480);
    expect(smartScrollOffset(1, 480, viewport, item, count)).toBe(0);
  });
});
