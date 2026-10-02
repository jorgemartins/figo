import { describe, expect, it } from "vitest";
import { channels, parseColor } from "./colors";

describe("parseColor", () => {
  it("reads 6-digit hex", () => {
    expect(parseColor("#1e5ac7")).toEqual({ r: 30, g: 90, b: 199, a: 1 });
    expect(parseColor("#FFFFFF")).toEqual({ r: 255, g: 255, b: 255, a: 1 });
  });

  it("reads 3- and 4-digit hex", () => {
    expect(parseColor("#000")).toEqual({ r: 0, g: 0, b: 0, a: 1 });
    expect(parseColor("#f808")).toEqual({ r: 255, g: 136, b: 0, a: 0.533 });
  });

  it("keeps the alpha of 8-digit hex as transparency instead of darkening the colour", () => {
    // atlantic-night's selection; upstream turned it into the opaque rgb(12 23 38).
    expect(parseColor("#396cb335")).toEqual({ r: 57, g: 108, b: 179, a: 0.208 });
    expect(parseColor("#ADD7FF40")).toEqual({ r: 173, g: 215, b: 255, a: 0.251 });
  });

  it("reads rgb() with spaces after the commas, which upstream rejected", () => {
    expect(parseColor("rgb(0, 255, 0)")).toEqual({ r: 0, g: 255, b: 0, a: 1 });
    expect(parseColor("rgb(106, 142, 218)")).toEqual({ r: 106, g: 142, b: 218, a: 1 });
    expect(parseColor("rgb(48,48,48)")).toEqual({ r: 48, g: 48, b: 48, a: 1 });
  });

  it("reads rgba() and the space-separated form with an alpha", () => {
    expect(parseColor("rgba(10, 20, 30, 0.5)")).toEqual({ r: 10, g: 20, b: 30, a: 0.5 });
    expect(parseColor("rgb(10 20 30 / 25%)")).toEqual({ r: 10, g: 20, b: 30, a: 0.25 });
    expect(parseColor("rgb(100% 0% 50%)")).toEqual({ r: 255, g: 0, b: 127.5, a: 1 });
  });

  it("clamps out-of-range channels", () => {
    expect(parseColor("rgb(300, -4, 12)")).toEqual({ r: 255, g: 0, b: 12, a: 1 });
  });

  it("rejects what it cannot read", () => {
    expect(parseColor("#00000")).toBeNull(); // halloween's typo
    expect(parseColor("#12345g")).toBeNull();
    expect(parseColor("rgb(1, 2)")).toBeNull();
    expect(parseColor("rgb(a, b, c)")).toBeNull();
    expect(parseColor("hsl(0 0% 0%)")).toBeNull();
    expect(parseColor("blue")).toBeNull();
    expect(parseColor(42)).toBeNull();
    expect(parseColor(undefined)).toBeNull();
  });

  it("accepts transparent", () => {
    expect(parseColor("transparent")).toEqual({ r: 0, g: 0, b: 0, a: 0 });
  });
});

describe("channels", () => {
  it("formats the space-separated triple the stylesheet expects", () => {
    expect(channels({ r: 48, g: 48, b: 48, a: 1 })).toBe("48 48 48");
  });
});
