/**
 * Shell history: history mode (ctrl+r) and the `history` template.
 */
import { describe, expect, it } from "vitest";
import { historyItems, readShellHistory } from "../history/history";
import { harness, monorepoBridge, shown, withSpecs } from "./fixtures";

const ZSH_HISTORY = [
  "git checkout main",
  "ls -la",
  "git status",
  'git commit -m "fix bug"',
  "git checkout feature/login",
  "ssh deploy@prod.example.com",
  "ssh -p 2222 staging.example.com",
  "git status",
].join("\n");

function historyBridge() {
  return monorepoBridge().onProcess("/bin/zsh -lic fc -R; fc -ln 1", { stdout: ZSH_HISTORY });
}

describe("history mode", () => {
  it("replaces the list with past command lines that continue what is typed, newest first", async () => {
    const h = harness(historyBridge());
    await h.typeOut("git ");
    await h.press("toggleHistoryMode");
    expect(h.bridge.processRuns()).toContain("/bin/zsh -lic fc -R; fc -ln 1");
    expect(h.core.getState()).toMatchObject({ historyMode: true, visible: true });
    // Lines whose first word recurs (status, checkout) rank above the one-off commit.
    expect(shown(h.core)).toEqual(["status", "checkout feature/login", "checkout main", 'commit -m "fix bug"']);
    expect(h.core.getState().suggestions[0]).toMatchObject({
      type: "history",
      icon: "📚",
      description: "past command",
    });
    await h.press("navigateDown");
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(["checkout feature/login"]);
  });

  it("includes commands run in this session and ends with the line", async () => {
    const h = harness(historyBridge());
    h.bridge.emit("postExec", { sessionId: "session-1", command: "git stash pop", exitCode: 0 });
    await h.typeOut("git st");
    await h.press("toggleHistoryMode");
    expect(shown(h.core)).toEqual(["status", "stash pop"]);
    h.bridge.type("");
    await h.idle();
    await h.typeOut("git st");
    expect(h.core.getState().historyMode).toBe(false);
  });

  it("never offers a multi-line entry, whose first line would run at once (review M13)", async () => {
    const h = harness(historyBridge());
    h.bridge.emit("postExec", { sessionId: "session-1", command: "git status &&\necho done", exitCode: 0 });
    h.bridge.emit("postExec", { sessionId: "session-1", command: "git stash\u0015list", exitCode: 0 });
    await h.typeOut("git st");
    await h.press("toggleHistoryMode");
    expect(shown(h.core)).toEqual(["status"]);
    expect(historyItems(["a\nb", "a b", "c\rd"], "").map((item) => item.names[0])).toEqual(["a b"]);
  });

  it("continues inside an open quote", async () => {
    const h = harness(historyBridge());
    // ctrl+r only works while there is a list, like every action; the mode lasts for the line.
    await h.typeOut("git ");
    await h.press("toggleHistoryMode");
    await h.typeOut('git commit -m "fi', "git ");
    expect(shown(h.core)).toEqual(['fix bug"']);
    await h.press("insertSelected");
    expect(h.bridge.inserts()).toEqual(['x bug"']);
  });

  it("is always on with beta.history.mode = history_only", async () => {
    const bridge = historyBridge();
    bridge.settings = { "beta.history.mode": "history_only" };
    const h = harness(bridge);
    await h.typeOut("git ");
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(h.core.getState().historyMode).toBe(true);
    expect(shown(h.core)).toEqual(["status", "checkout feature/login", "checkout main", 'commit -m "fix bug"']);
  });

  it("reads each shell's history its own way", async () => {
    const runs: string[] = [];
    const run = async (executable: string, args: string[]) => {
      runs.push([executable, ...args].join(" "));
      return executable.endsWith("fish") ? "newest\nolder\n" : "  1  ignored\n\tls -la\n";
    };
    expect(await readShellHistory(run, "fish", "/opt/homebrew/bin/fish", undefined)).toEqual(["older", "newest"]);
    expect(await readShellHistory(run, "bash", "/bin/bash", undefined)).toEqual(["1  ignored", "ls -la"]);
    expect(await readShellHistory(run, "zsh", "/bin/zsh", "cat ~/.my_history")).toEqual(["  1  ignored", "\tls -la"]);
    expect(runs).toEqual([
      "/opt/homebrew/bin/fish -lic history search",
      "/bin/bash -lic fc -ln 1",
      "zsh -c cat ~/.my_history",
    ]);
  });

  it("ranks by how often the first word recurs", () => {
    const items = historyItems(["a x", "a y", "b z", "a x"], "");
    expect(items.map((item) => [item.names[0], item.priority])).toEqual([
      ["a x", 75.3],
      ["a y", 75.3],
      ["b z", 50],
    ]);
  });
});

describe("history template", () => {
  it("offers values given to the same argument before (ssh hosts)", async () => {
    const h = harness(historyBridge());
    await h.typeOut("ssh ");
    // Most recent first; ssh's options follow.
    expect(shown(h.core).slice(0, 3)).toEqual(["staging.example.com", "deploy@prod.example.com", "-1"]);
    expect(
      h.core
        .getState()
        .suggestions.slice(0, 2)
        .map((s) => s.type),
    ).toEqual(["arg", "arg"]);
    await h.typeOut("ssh d", "ssh ");
    expect(shown(h.core)).toEqual(["deploy@prod.example.com"]);
  });

  it("keeps history next to filepaths in one template (upstream dropped it)", async () => {
    const spec: Fig.Spec = {
      name: "tool",
      args: { template: ["history", "filepaths"] },
      options: [{ name: "-x", args: {} }],
    };
    const bridge = historyBridge().onProcess("/bin/zsh -lic fc -R; fc -ln 1", {
      stdout: "tool -x 1 remembered.txt\ntool other.txt",
    });
    const h = harness(bridge, withSpecs({ tool: spec }));
    await h.typeOut("tool ");
    const names = shown(h.core);
    expect(names).toContain("other.txt");
    expect(names).toContain("remembered.txt");
    expect(names).toContain("apps/");
    // `1` went to -x, not to the argument.
    expect(names).not.toContain("1");
  });
});
