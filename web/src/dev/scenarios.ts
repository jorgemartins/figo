import type { Settings } from "../bridge/contract";
import type { ArgumentHint, ArgumentInfo, Suggestion, SuggestionType } from "../core/contract";

/** A suggestion as a scenario lists it; the fake core adds the match ranges. */
export type ScenarioSuggestion = Omit<Suggestion, "match">;

export type Prompt =
  /** `~ ` in a blue powerline segment. */
  | { kind: "home" }
  /** `~/Sites/storefront` in blue, then the branch in green. */
  | { kind: "project"; path: string; branch: string };

/** A line of earlier terminal output: plain text, coloured runs, or an earlier prompt. */
export type TerminalLine =
  | string
  | { parts: Array<{ text: string; tone?: "teal" }> }
  | { prompt: Prompt; command: string };

export interface Scenario {
  id: string;
  label: string;
  /** What it reproduces, shown under the picker. */
  note: string;
  /** Terminal output above the prompt line. */
  preamble: TerminalLine[];
  prompt: Prompt;
  /** Text on the command line before the part being completed. */
  command: string;
  /** The part being completed, which filters the list. */
  query?: string;
  suggestions: ScenarioSuggestion[];
  argument?: ArgumentInfo | null;
  loading?: boolean;
  descriptionPopout?: boolean;
  settings?: Settings;
  /** Blank terminal lines after the preamble, to move the prompt (and caret) down. */
  pushDown?: number;
  /** Spaces typed before the prompt's command, to move the caret right. */
  indent?: number;
  /** Inserting the suggestion with this first name loads another scenario. */
  next?: Record<string, string>;
}

const LOGIN = "Last login: Thu Oct  1 23:50:27 on ttys006";
const PROJECT_PREAMBLE: TerminalLine[] = [
  LOGIN,
  { prompt: { kind: "home" }, command: "cd Sites/storefront/" },
  { parts: [{ text: "Using Node " }, { text: "v26.7.0", tone: "teal" }] },
];
const PROJECT: Prompt = { kind: "project", path: "~/Sites/storefront", branch: "staging" };

function folder(name: string): ScenarioSuggestion {
  return { type: "folder", names: [`${name}/`] };
}

function script(name: string, description: string): ScenarioSuggestion {
  return { type: "arg", names: [name], description, icon: "fig://icon?type=npm" };
}

function arg(name: string, options: Partial<ArgumentHint> = {}): ArgumentHint {
  return { name, isOptional: false, isVariadic: false, ...options };
}

function sub(names: string[], description: string, args?: ArgumentHint[], type: SuggestionType = "subcommand"): ScenarioSuggestion {
  return { type, names, description, args };
}

const HOME_FOLDERS = [
  "Sites",
  "Applications",
  "Beta Projects",
  "Desktop",
  "Development",
  "Documents",
  "Downloads",
  "Library",
  "Movies",
  "Music",
  "Pictures",
  "Public",
].map(folder);

const SITES_FOLDERS: ScenarioSuggestion[] = [
  { type: "auto-execute", names: ["↪"], description: "Enter the current directory" },
  ...["storefront", "blog", "api-server", "design-system", "dotfiles", "figo", "notes"].map(folder),
];

const SCRIPTS: ScenarioSuggestion[] = [
  script("dev:bg:stop", "tsx scripts/dev/run-background.ts stop"),
  script("dev:serve:bg", "tsx scripts/dev/run-background.ts start serve"),
  script("dev", "turbo run dev --filter=./apps/*"),
  script("clean", "tsx scripts/clean.ts"),
  script("db:reset", "pnpm --filter @app/db reset && pnpm --filter @app/db seed"),
  script("storybook", "storybook dev -p 6006"),
  script("dev:bg:status", "tsx scripts/dev/run-background.ts status"),
  script("build", "turbo run build"),
  script("lint", "eslint . --max-warnings=0"),
  script("typecheck", "tsc -b"),
];

const PNPM: ScenarioSuggestion[] = [
  sub(
    ["install", "i"],
    "Pnpm install is used to install all dependencies for a project. In a CI environment, installation fails if a lockfile is present but needs an update",
    [arg("package", { isOptional: true, isVariadic: true })],
  ),
  script("dev:serve", "tsx scripts/dev/serve.ts"),
  script("seed", "tsx scripts/seed.ts"),
  script("dev:serve:bg", "tsx scripts/dev/run-background.ts start serve"),
  script("dev:bg:stop", "tsx scripts/dev/run-background.ts stop"),
  script("test:unit", "vitest run --project unit"),
  sub(["add"], "Installs a package and any packages that it depends on", [arg("package", { isVariadic: true })]),
  sub(["run", "run-script"], "Runs a script defined in the package's manifest file", [arg("script"), arg("args", { isOptional: true, isVariadic: true })]),
  sub(["exec"], "Execute a shell command in scope of a project", [arg("command")]),
  sub(["-r", "--recursive"], "Run the command for every project in the workspace", undefined, "option"),
];

const GIT: ScenarioSuggestion[] = [
  sub(["checkout", "co"], "Switch branches or restore working tree files", [arg("branch", { isOptional: true }), arg("pathspec", { isOptional: true, isVariadic: true })]),
  sub(["cherry-pick"], "Apply the changes introduced by some existing commits", [arg("commit", { isVariadic: true })]),
  sub(["cherry"], "Find commits yet to be applied to upstream", [arg("upstream", { isOptional: true })]),
  sub(["clean"], "Remove untracked files from the working tree"),
  sub(["clone"], "Clone a repository into a new directory", [arg("repository"), arg("directory", { isOptional: true })]),
  sub(["commit"], "Record changes to the repository", [arg("pathspec", { isOptional: true, isVariadic: true })]),
  sub(["config"], "Get and set repository or global options"),
  { type: "shortcut", names: ["git co -"], description: "Check out the previous branch" },
  { type: "mixin", names: ["git sync"], description: "Your own mixin: fetch, rebase and push" },
];

const LONG: ScenarioSuggestion[] = [
  sub(
    ["describe-application-auto-scaling-policies", "describe-scaling-policies"],
    "Describes the Application Auto Scaling scaling policies for the specified service namespace, which can be any of the scalable targets registered for it",
    [arg("service-namespace"), arg("resource-id", { isOptional: true }), arg("scalable-dimension", { isOptional: true })],
  ),
  sub(["--endpoint-url"], "Override command's default URL with the given URL", [arg("url")], "option"),
  { type: "file", names: ["a-very-long-file-name-that-keeps-going-and-going-past-the-edge.tar.gz"] },
  { type: "special", names: ["🔥 special item with an emoji icon"], icon: "🔥", description: "Short text and emoji icons are drawn as text" },
  { type: "arg", names: ["docker-compose.override.yml"], icon: "fig://icon?type=docker&color=e67e22&badge=2", description: "A named icon with a corner badge" },
  { type: "arg", names: ["remote-image-from-https"], icon: "https://example.invalid/icon.png", description: "Remote images that fail show nothing, as upstream" },
  { type: "history", names: ["git log --oneline --graph --decorate --all"], description: "past command" },
];

/** Every named icon, to eyeball the asset set. */
const ICON_NAMES = [
  "command", "option", "carrot", "box", "asterisk", "flag", "alert", "characters", "commandkey", "database",
  "gear", "invite", "package", "string", "cpu", "npm", "git", "github", "template", "symlink", "folder", "file",
  "android", "apple", "aws", "azure", "commit", "discord", "docker", "firebase", "gcloud", "gitlab", "gradle",
  "heroku", "kubernetes", "netlify", "node", "okteto", "slack", "twitter", "vercel", "yarn",
];

export const HARBOR_THEME_NAME = "figo-harbor";

/**
 * A custom theme file written for the harness. It deliberately uses the two colour forms upstream
 * mis-parsed: spaced `rgb()` values and 8-digit hex with alpha.
 */
export const HARBOR_THEME = {
  author: { name: "Figo dev harness" },
  version: "1.0",
  theme: {
    textColor: "rgb(214, 222, 235)",
    backgroundColor: "#13203a",
    matchBackgroundColor: "#c7924a80",
    selection: {
      textColor: "#ffffff",
      backgroundColor: "#3d7ef0aa",
    },
    description: {
      textColor: "rgb(150, 178, 214)",
      borderColor: "#2a3b5c",
    },
  },
};

export const SCENARIOS: Scenario[] = [
  {
    id: "cd",
    label: "1 · cd (folders, footer)",
    note: "Reference shot 1: folder list, \"folder\" in the footer, ⌃k hint. Enter on Sites/ goes to shot 2.",
    preamble: [LOGIN],
    prompt: { kind: "home" },
    command: "cd ",
    suggestions: HOME_FOLDERS,
    next: { "Sites/": "cd-sites" },
  },
  {
    id: "cd-sites",
    label: "2 · cd Sites/ (↪ row)",
    note: "Reference shot 2: the auto-execute ↪ row with the carrot icon.",
    preamble: [LOGIN],
    prompt: { kind: "home" },
    command: "cd Sites/",
    suggestions: SITES_FOLDERS,
  },
  {
    id: "nr",
    label: "3 · nr (npm scripts)",
    note: "Reference shot 3: npm icons, script body in the footer.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "nr ",
    suggestions: SCRIPTS,
  },
  {
    id: "nr-panel",
    label: "4 · nr + side panel",
    note: "Reference shot 4: ⌃k moves the description to the panel; 7 rows fit.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "nr ",
    suggestions: SCRIPTS,
    descriptionPopout: true,
  },
  {
    id: "pnpm",
    label: "5 · pnpm (install, i [package...])",
    note: "Reference shot 5: subcommand icon, joined names, dimmed args, footer clipped by the hint.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "pnpm ",
    suggestions: PNPM,
  },
  {
    id: "match",
    label: "Match + common prefix",
    note: "Typed \"de\": the match is highlighted and the shared \"v\" (what Tab inserts) underlined.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "nr ",
    query: "de",
    suggestions: SCRIPTS,
  },
  {
    id: "git",
    label: "git (types, shortcut, mixin)",
    note: "Default icons per type, including the tinted template tiles with badges.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "git ",
    suggestions: GIT,
  },
  {
    id: "loading",
    label: "Loading",
    note: "Generators still running after 200ms: the dots replace the popup.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "git checkout ",
    suggestions: [],
    loading: true,
  },
  {
    id: "argument",
    label: "Argument hint",
    note: "Nothing to suggest, but the argument has a name and description.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "git commit -m ",
    suggestions: [],
    argument: { name: "message", description: "Use the given <msg> as the commit message" },
  },
  {
    id: "long",
    label: "Long names + misc icons",
    note: "Names are clipped hard (no ellipsis); emoji, badge, remote and history icons.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "aws application-autoscaling ",
    suggestions: LONG,
  },
  {
    id: "icons",
    label: "Every named icon",
    note: "fig://icon?type=<name> for every name Figo draws itself.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "icons ",
    suggestions: ICON_NAMES.map((name) => ({ type: "arg", names: [name], icon: `fig://icon?type=${name}`, description: `fig://icon?type=${name}` })),
    settings: { "autocomplete.height": 460 },
  },
  {
    id: "light",
    label: "Light theme",
    note: "autocomplete.theme = light.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "pnpm ",
    query: "d",
    suggestions: PNPM,
    settings: { "autocomplete.theme": "light" },
  },
  {
    id: "custom-theme",
    label: "Custom theme",
    note: "A theme file with spaced rgb() values and 8-digit hex alpha (both fixed here).",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "nr ",
    query: "dev",
    suggestions: SCRIPTS,
    settings: { "autocomplete.theme": HARBOR_THEME_NAME },
  },
  {
    id: "above",
    label: "Above the caret",
    note: "No room below the caret: the window goes above, and the short list hugs the caret while the taller panel stays top-aligned.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "nr ",
    query: "dev:bg",
    suggestions: SCRIPTS,
    descriptionPopout: true,
    pushDown: 17,
  },
  {
    id: "left-panel",
    label: "Panel on the left",
    note: "The panel would leave the screen on the right, so it goes left and the window shifts -200px.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "nr ",
    suggestions: SCRIPTS,
    descriptionPopout: true,
    indent: 23,
  },
  {
    id: "font",
    label: "Font + size settings",
    note: "autocomplete.fontSize = 15, fontFamily = Menlo, width 380.",
    preamble: PROJECT_PREAMBLE,
    prompt: PROJECT,
    command: "pnpm ",
    suggestions: PNPM,
    settings: { "autocomplete.fontSize": 15, "autocomplete.fontFamily": "Menlo", "autocomplete.width": 380 },
  },
];

export const HISTORY: ScenarioSuggestion[] = [
  "pnpm --dir web dev",
  "git status",
  "swift build -c release",
  "pnpm --dir web exec vitest run src/ui",
  "open -a Ghostty",
].map((line) => ({ type: "history", names: [line], icon: "📚", description: "past command" }));
