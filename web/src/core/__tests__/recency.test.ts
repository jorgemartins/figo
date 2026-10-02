/**
 * Recency of picked suggestions (engine doc §6.4), persisted through CoreOptions.storage.
 */
import { describe, expect, it } from "vitest";
import { rankItems, sortByRank } from "../suggestions/rank";
import { MAX_RECENCY_COMMANDS, MAX_RECENCY_NAMES, RecencyIndex, memoryStorage } from "../suggestions/recency";
import type { Item } from "../suggestions/types";
import { harness, monorepoBridge, select, shown } from "./fixtures";

const item = (name: string, priority?: number): Item => ({ type: "arg", names: [name], priority });

describe("ranking", () => {
  it("lifts recently used entries with ordinary priority just above 75, newest first", () => {
    const recency = new RecencyIndex(memoryStorage());
    recency.record("git", "old", 1_700_000_000_000);
    recency.record("git", "new", 1_760_000_000_000);
    const ranked = sortByRank(
      rankItems([item("a"), item("old"), item("b", 90), item("new"), item("low", 20)], "git", recency),
    );
    expect(ranked.map((entry) => entry.names[0])).toEqual(["b", "new", "old", "a", "low"]);
    expect(ranked[1]?.rank).toBeCloseTo(75.176);
  });

  it("treats priority 0 as 50, clamps to 0–100, and never boosts ../", () => {
    const recency = new RecencyIndex(memoryStorage());
    recency.record("ls", "../");
    const ranked = rankItems([item("zero", 0), item("huge", 500), item("../")], "ls", recency);
    expect(ranked.map((entry) => entry.rank)).toEqual([50, 100, 50]);
  });

  it("keeps the index bounded, dropping the least recently used (review L20)", () => {
    const storage = memoryStorage();
    const recency = new RecencyIndex(storage);
    let at = 1_000_000;
    for (let i = 0; i < MAX_RECENCY_NAMES + 10; i += 1) {
      recency.record("first", `name${i}`, (at += 1));
    }
    for (let i = 0; i < MAX_RECENCY_COMMANDS + 10; i += 1) {
      recency.record(`cmd${i}`, "name", (at += 1));
    }
    const stored = JSON.parse(storage.getItem("figo.recency") ?? "{}") as Record<string, Record<string, number>>;
    expect(Object.keys(stored)).toHaveLength(MAX_RECENCY_COMMANDS);
    // The commands used longest ago are gone; the latest picks survive.
    expect(stored.first).toBeUndefined();
    expect(recency.lastUsed("cmd0", "name")).toBeUndefined();
    expect(recency.lastUsed(`cmd${MAX_RECENCY_COMMANDS + 9}`, "name")).toBe(at);
    // Within a command, only the most recent names are kept.
    const names = new RecencyIndex(memoryStorage());
    for (let i = 0; i < MAX_RECENCY_NAMES + 10; i += 1) {
      names.record("git", `name${i}`, 1_000 + i);
    }
    expect(names.lastUsed("git", "name0")).toBeUndefined();
    expect(names.lastUsed("git", `name${MAX_RECENCY_NAMES + 9}`)).toBe(1_000 + MAX_RECENCY_NAMES + 9);
    expect(names.lastUsed("git", "name10")).toBe(1_010);
  });

  it("ignores ↪ entries", () => {
    const storage = memoryStorage();
    new RecencyIndex(storage).record("cd", "↪");
    expect(storage.getItem("figo.recency")).toBeNull();
  });
});

describe("recency through the core", () => {
  it("persists picks in the given storage and uses them in later sessions", async () => {
    const storage = memoryStorage();
    const first = harness(monorepoBridge(), { storage });
    await first.typeOut("git ");
    const firstOrder = shown(first.core);
    await select(first, "stash");
    await first.press("insertSelected");
    expect(JSON.parse(storage.getItem("figo.recency") ?? "{}")).toEqual({ git: { stash: expect.any(Number) } });

    const second = harness(monorepoBridge(), { storage });
    await second.typeOut("git ");
    expect(shown(second.core)[0]).toBe("stash");
    expect(shown(second.core).slice(1)).toEqual(firstOrder.filter((name) => name !== "stash"));
  });

  it("is keyed by the command the spec belongs to (sudo git → git)", async () => {
    const storage = memoryStorage();
    const h = harness(monorepoBridge(), { storage });
    await h.typeOut("sudo git sta");
    await select(h, "stash");
    await h.press("insertSelected");
    expect(Object.keys(JSON.parse(storage.getItem("figo.recency") ?? "{}"))).toEqual(["git"]);
  });

  it("is off with sortMethod alphabetical", async () => {
    const storage = memoryStorage();
    new RecencyIndex(storage).record("git", "stash");
    const bridge = monorepoBridge();
    bridge.settings = { "autocomplete.sortMethod": "alphabetical" };
    const h = harness(bridge, { storage });
    await h.typeOut("git ");
    expect(shown(h.core)[0]).not.toBe("stash");
  });
});
