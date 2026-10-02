import { describe, expect, it } from "vitest";
import { alwaysShowDescription, computeMetrics, fontFamilySetting, themeSetting } from "./metrics";

describe("computeMetrics", () => {
  it("uses the measured defaults", () => {
    expect(computeMetrics({}, 1, false)).toEqual({
      fontSize: 12.8,
      itemSize: 20,
      iconSize: 15,
      listWidth: 320,
      maxHeight: 140,
      panelMaxHeight: 140,
    });
  });

  it("derives row and icon size from the font size, but not width or height", () => {
    const metrics = computeMetrics({ "autocomplete.fontSize": 16 }, 1, false);
    expect(metrics.itemSize).toBe(25);
    expect(metrics.iconSize).toBe(18.75);
    expect(metrics.listWidth).toBe(320);
    expect(metrics.maxHeight).toBe(140);
  });

  it("ignores invalid sizes", () => {
    expect(computeMetrics({ "autocomplete.fontSize": 0, "autocomplete.width": "wide", "autocomplete.height": -1 }, 1, false)).toMatchObject({
      fontSize: 12.8,
      listWidth: 320,
      maxHeight: 140,
    });
  });

  it("widens by 50px for history unless a width is set", () => {
    expect(computeMetrics({}, 1, true).listWidth).toBe(370);
    expect(computeMetrics({ "beta.history.mode": "show" }, 1, false).listWidth).toBe(370);
    expect(computeMetrics({ "autocomplete.width": 400 }, 1, true).listWidth).toBe(400);
  });

  it("scales font, rows, width and height together for the session, but not the panel height", () => {
    const metrics = computeMetrics({}, 1.1, false);
    expect(metrics.fontSize).toBeCloseTo(14.08);
    expect(metrics.itemSize).toBeCloseTo(22);
    expect(metrics.listWidth).toBeCloseTo(352);
    expect(metrics.maxHeight).toBeCloseTo(154);
    expect(metrics.panelMaxHeight).toBe(140);
  });
});

describe("settings helpers", () => {
  it("reads the font family, theme and side-panel settings", () => {
    expect(fontFamilySetting({})).toBeUndefined();
    expect(fontFamilySetting({ "autocomplete.fontFamily": " " })).toBeUndefined();
    expect(fontFamilySetting({ "autocomplete.fontFamily": "Menlo" })).toBe("Menlo");
    expect(themeSetting({ "autocomplete.theme": "dracula" })).toBe("dracula");
    expect(themeSetting({ "autocomplete.theme": 3 })).toBeUndefined();
    expect(alwaysShowDescription({ "autocomplete.alwaysShowDescription": true })).toBe(true);
    expect(alwaysShowDescription({})).toBe(false);
  });
});
