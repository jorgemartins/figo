import { describe, expect, it } from "vitest";
import { descriptionHint, formatKey } from "./hint";

describe("formatKey", () => {
  it("maps modifiers to their glyphs and keeps the key", () => {
    expect(formatKey("control+k")).toBe("⌃k");
    expect(formatKey("ctrl+k")).toBe("⌃k");
    expect(formatKey("command+i")).toBe("⌘i");
    expect(formatKey("cmd+shift+d")).toBe("⌘⇧d");
    expect(formatKey("meta+option+x")).toBe("⌘⌥x");
    expect(formatKey("opt+d")).toBe("⌥d");
  });

  it("leaves alt alone, as upstream", () => {
    expect(formatKey("alt+d")).toBe("altd");
  });
});

describe("descriptionHint", () => {
  it("defaults to ⌃k", () => {
    expect(descriptionHint({})).toBe("⌃k");
  });

  it("uses the first key bound to a description action", () => {
    expect(
      descriptionHint({
        "autocomplete.theme": "dark",
        "autocomplete.keybindings.tab": "insertSelected",
        "autocomplete.keybindings.command+i": "toggleDescription",
        "autocomplete.keybindings.control+d": "showDescription",
      }),
    ).toBe("⌘i");
    expect(descriptionHint({ "autocomplete.keybindings.control+shift+h": "hideDescription" })).toBe("⌃⇧h");
  });

  it("ignores settings that are not keybindings", () => {
    expect(descriptionHint({ "something.else": "toggleDescription" })).toBe("⌃k");
  });

  it("shows nothing when the default key was unbound and no other key replaces it", () => {
    expect(descriptionHint({ "autocomplete.keybindings.control+k": "ignore" })).toBeNull();
    expect(descriptionHint({ "autocomplete.keybindings.control+k": "navigateUp" })).toBeNull();
    expect(descriptionHint({ "autocomplete.keybindings.control+k": "toggleDescription" })).toBe("⌃k");
  });
});
