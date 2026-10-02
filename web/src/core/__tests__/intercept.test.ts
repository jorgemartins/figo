/**
 * Key interception (`shell.setIntercept`) and keybinding events.
 */
import { describe, expect, it } from "vitest";
import { DEFAULT_BINDINGS, normalizeBinding } from "../state/bindings";
import { harness, monorepoBridge, select } from "./fixtures";

describe("shell.setIntercept", () => {
  it("captures bound keys while the list is visible, and nothing without suggestions", async () => {
    const h = harness();
    await h.typeOut("git ch");
    expect(h.bridge.lastIntercept()).toEqual({
      sessionId: "session-1",
      interceptBound: true,
      interceptGlobal: true,
      bindings: { ...DEFAULT_BINDINGS },
    });
    await h.typeOut("cd zzz", "");
    expect(h.bridge.lastIntercept()).toMatchObject({ interceptBound: false, interceptGlobal: false });
  });

  it("keeps only global keys after Esc, and none right after an insertion", async () => {
    const h = harness();
    await h.typeOut("git ch");
    await h.press("hideAutocomplete");
    expect(h.bridge.lastIntercept()).toMatchObject({ interceptBound: false, interceptGlobal: true });
    await h.press("showAutocomplete");
    expect(h.bridge.lastIntercept()).toMatchObject({ interceptBound: true, interceptGlobal: true });
    await select(h, "checkout");
    await h.press("insertSelected");
    expect(h.bridge.lastIntercept()).toMatchObject({ interceptBound: false, interceptGlobal: false });
  });

  it("is only sent when something changed", async () => {
    const h = harness();
    await h.typeOut("git ch");
    const before = h.bridge.callsTo("shell.setIntercept").length;
    await h.typeOut("git che", "git ch");
    await h.press("navigateDown");
    expect(h.bridge.callsTo("shell.setIntercept").length).toBe(before);
  });

  it("merges user keybindings over the defaults, and `ignore` unbinds", async () => {
    const bridge = monorepoBridge();
    bridge.settings = {
      "autocomplete.keybindings.ctrl+k": "ignore",
      "autocomplete.keybindings.tab": "insertSelected",
      "autocomplete.keybindings.command+i": "toggleDescription",
    };
    const h = harness(bridge);
    await h.typeOut("git ch");
    expect(bridge.lastIntercept()?.bindings).toEqual({
      ...DEFAULT_BINDINGS,
      "control+k": "ignore",
      tab: "insertSelected",
      "command+i": "toggleDescription",
    });
    bridge.emitSettings({ "autocomplete.keybindings.enter": "insertSelectedAndExecute" });
    await h.idle();
    expect(bridge.lastIntercept()?.bindings).toEqual({ ...DEFAULT_BINDINGS, enter: "insertSelectedAndExecute" });
  });

  it("names keys one way", () => {
    expect(normalizeBinding("Ctrl+K")).toBe("control+k");
    expect(normalizeBinding("shift+ctrl+ArrowUp")).toBe("control+shift+up");
    expect(normalizeBinding("cmd+opt+i")).toBe("option+command+i");
  });

  it("follows the focused session", async () => {
    const h = harness();
    await h.typeOut("git ch");
    h.bridge.startSession({ sessionId: "session-2", cwd: "/Users/test/Sites/mono", home: "/Users/test" });
    await h.typeOut("git ch");
    expect(h.bridge.lastIntercept()).toMatchObject({ sessionId: "session-2", interceptBound: true });
    expect(h.core.getState().sessionId).toBe("session-2");
  });
});

describe("keybinding events", () => {
  it("are dispatched as actions for the focused session only", async () => {
    const h = harness();
    await h.typeOut("git ch");
    await h.press("navigateDown");
    expect(h.core.getState().selectedIndex).toBe(1);
    h.bridge.emit("keybinding", { sessionId: "other", action: "navigateDown" });
    h.bridge.emit("keybinding", { sessionId: "session-1", action: "selectSuggestion3" });
    await h.idle();
    expect(h.core.getState().selectedIndex).toBe(1);
  });

  it("keeps the selected entry selected when the list changes", async () => {
    const h = harness();
    await h.typeOut("git ch");
    await select(h, "cherry-pick");
    await h.typeOut("git che", "git ch");
    expect(h.core.getState().suggestions[h.core.getState().selectedIndex]?.names[0]).toBe("cherry-pick");
  });

  it("clicking a row inserts it", async () => {
    const h = harness();
    await h.typeOut("git ch");
    const index = h.core.getState().suggestions.findIndex((s) => s.names[0] === "cherry-pick");
    expect(index).toBeGreaterThan(0);
    h.core.insert(index);
    expect(h.bridge.inserts()).toEqual(["erry-pick "]);
  });
});
