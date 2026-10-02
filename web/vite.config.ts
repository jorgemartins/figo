import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import react from "@vitejs/plugin-react";
import type { Plugin } from "vite";
import { defineConfig } from "vitest/config";

/**
 * Dev server only: serves the theme files of a directory (FIGO_THEMES_DIR, e.g. the themes that
 * scripts/bundle.sh fetches) under /__themes so the harness can try them without copying them.
 */
function devThemes(directory: string | undefined): Plugin {
  return {
    name: "figo-dev-themes",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use("/__themes", (request, response, next) => {
        if (!directory) {
          next();
          return;
        }
        const name = decodeURIComponent((request.url ?? "").replace(/^\//, "").replace(/\?.*$/, ""));
        try {
          if (name === "index.json") {
            const names = readdirSync(directory)
              .filter((file) => file.endsWith(".json"))
              .map((file) => file.slice(0, -".json".length))
              .sort();
            response.setHeader("Content-Type", "application/json");
            response.end(JSON.stringify(names));
            return;
          }
          if (!/^[\w.-]+\.json$/.test(name)) {
            next();
            return;
          }
          response.setHeader("Content-Type", "application/json");
          response.end(readFileSync(join(directory, name)));
        } catch {
          response.statusCode = 404;
          response.end();
        }
      });
    },
  };
}

/**
 * Dev server only: lets the page's Content-Security-Policy (index.html) reach Vite's hot-reload
 * WebSocket, which not every browser counts as 'self'. The built page keeps the policy as written.
 */
function devContentSecurityPolicy(): Plugin {
  return {
    name: "figo-dev-csp",
    apply: "serve",
    transformIndexHtml(html) {
      return html.replace(/connect-src ([^;"]*)/, "connect-src $1 ws: wss:");
    },
  };
}

export default defineConfig({
  plugins: [react(), devThemes(process.env.FIGO_THEMES_DIR), devContentSecurityPolicy()],
  // The app serves these files from its bundle under a custom scheme, so asset URLs must be relative.
  base: "./",
  build: {
    target: "safari17",
    outDir: "dist",
    emptyOutDir: true,
  },
  test: {
    environment: "node",
    include: ["src/**/*.test.ts", "src/**/*.test.tsx"],
  },
});
