import type { NativeBridge, SessionId } from "../../bridge/contract";
import type { ExecuteCommand } from "../specs/types";
import { isObject } from "../utils";
import { listLikeLs } from "./paths";

/** Cleans process output the way specs expect it: Unix newlines, no cursor-show escape, no edge newlines. */
export function cleanOutput(text: string): string {
  return text
    .replace(/\r\n/g, "\n")
    .replace(/\x1b\[\?25h/g, "")
    .replace(/^\n+|\n+$/g, "");
}

export interface ExecuteOptions {
  /** Used when the input names no `cwd`; undefined lets the session use the shell's directory. */
  cwd?: string;
  /** Minimum timeout in milliseconds. */
  timeoutMs: number;
}

/**
 * The `executeCommand` handed to spec code. Programs run directly (never through a shell) via the
 * session's pty wrapper. Two programs are answered locally: the `ls -1ApL` of path generators
 * becomes a directory listing over the bridge, and `fig` (which bundled `ai()` generators and some
 * specs call) is reported as unavailable so those generators return nothing.
 */
export function createExecuteCommand(
  bridge: NativeBridge,
  sessionId: SessionId,
  options: ExecuteOptions,
): ExecuteCommand {
  return async (input) => {
    if (!isObject(input) || typeof input.command !== "string" || input.command === "") {
      throw new Error("executeCommand expects { command, args }");
    }
    const args = Array.isArray(input.args) ? input.args.map(String) : [];
    const cwd = typeof input.cwd === "string" ? input.cwd : options.cwd;
    if (input.command === "ls" && args.length === 1 && args[0] === "-1ApL") {
      return { stdout: await listLikeLs(bridge, sessionId, cwd ?? "."), stderr: "", status: 0 };
    }
    if (input.command === "fig") {
      return { stdout: "", stderr: "fig is not available in Figo", status: 127 };
    }
    let env: Record<string, string | null> | undefined;
    if (isObject(input.env)) {
      env = {};
      for (const [key, value] of Object.entries(input.env)) {
        env[key] = typeof value === "string" ? value : null;
      }
    }
    const timeoutMs = Math.max(options.timeoutMs, typeof input.timeout === "number" ? input.timeout : 0);
    const result = await bridge.call("process.run", {
      sessionId,
      executable: input.command,
      args,
      ...(cwd !== undefined ? { cwd } : {}),
      ...(env !== undefined ? { env } : {}),
      timeoutMs,
    });
    return { stdout: cleanOutput(result.stdout), stderr: cleanOutput(result.stderr), status: result.exitCode };
  };
}

/** Used while indexing history: spec code must not run programs then. */
export const refuseToExecute: ExecuteCommand = () =>
  Promise.reject(new Error("Commands cannot run while reading history"));
