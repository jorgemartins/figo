import { directoryOfPath } from "../shell/expand";
import { isObject } from "../utils";
import { type GeneratedSuggestion, type GeneratorContext, type GeneratorServices, figContext } from "./context";
import { templateSuggestions } from "./templates";

type Update = (suggestions: GeneratedSuggestion[]) => void;

function hasName(item: unknown): boolean {
  if (typeof item === "string") {
    return item !== "";
  }
  if (!isObject(item)) {
    return false;
  }
  const { name } = item;
  return (
    (typeof name === "string" && name !== "") ||
    (Array.isArray(name) && name.some((n) => typeof n === "string" && n !== ""))
  );
}

function normalize(items: unknown, isDangerous: boolean): GeneratedSuggestion[] {
  if (!Array.isArray(items)) {
    return [];
  }
  return items
    .filter(hasName)
    .map((item: unknown) =>
      typeof item === "string"
        ? { type: "arg", name: item, insertValue: item, isDangerous }
        : { ...(item as GeneratedSuggestion), type: (item as GeneratedSuggestion).type ?? "arg" },
    );
}

/** Runs `fetch` through the generator's cache, if it has one. */
function cached<T>(
  generator: Fig.Generator,
  context: GeneratorContext,
  services: GeneratorServices,
  key: string | undefined,
  fetch: () => Promise<T>,
  onRevalidated: (value: T) => void,
): Promise<T> {
  const cache: Fig.Cache | undefined =
    generator.cache ?? (services.autoCache ? { strategy: "stale-while-revalidate", ttl: 1_000 } : undefined);
  if (cache === undefined) {
    return fetch();
  }
  const directory = generator.template
    ? directoryOfPath(context.searchTerm, context.cwd, context.env.HOME ?? "~", context.env)
    : context.cwd;
  const fullKey = [cache.cacheByDirectory ? directory : "", key ?? context.tokens.join(" ")].join("\u0000");
  return services.cache.run(fullKey, cache, fetch, onRevalidated);
}

async function scriptSuggestions(
  generator: Fig.Generator,
  context: GeneratorContext,
  services: GeneratorServices,
  onUpdate: Update,
): Promise<GeneratedSuggestion[]> {
  const { script, postProcess, splitOn } = generator;
  if (!script || !context.cwd) {
    return [];
  }
  const command = typeof script === "function" ? script(context.tokens) : script;
  if (!command) {
    return [];
  }
  const input: Fig.ExecuteCommandInput = Array.isArray(command)
    ? { command: String(command[0] ?? ""), args: command.slice(1).map(String), cwd: context.cwd }
    : { cwd: context.cwd, ...(command as Fig.ExecuteCommandInput) };
  const timeout = Math.max(services.scriptTimeout, generator.scriptTimeout ?? 0, input.timeout ?? 0);

  const toSuggestions = (stdout: string): GeneratedSuggestion[] => {
    try {
      if (splitOn) {
        return normalize(stdout.trim() === "" ? [] : stdout.trim().split(splitOn), context.isDangerous);
      }
      if (postProcess) {
        return normalize(postProcess(stdout, context.tokens), context.isDangerous);
      }
    } catch {
      // A postProcess that throws yields nothing, as upstream.
    }
    return [];
  };

  // The raw output is what gets cached; postProcess runs every time because it may look at the tokens.
  const stdout = await cached(
    generator,
    context,
    services,
    generator.cache?.cacheKey ?? JSON.stringify(input),
    async () => (await services.executeCommand(context.cwd, timeout)(input)).stdout,
    (fresh) => onUpdate(toSuggestions(fresh)),
  );
  return toSuggestions(stdout);
}

async function customSuggestions(
  generator: Fig.Generator,
  context: GeneratorContext,
  services: GeneratorServices,
  onUpdate: Update,
): Promise<GeneratedSuggestion[]> {
  const { custom } = generator;
  if (!custom || !context.cwd) {
    return [];
  }
  const filter = (items: unknown): GeneratedSuggestion[] => {
    const suggestions = normalize(items, context.isDangerous);
    // Template-shaped results (from filepaths-like generators) go through the spec's filter.
    if (generator.filterTemplateSuggestions && suggestions[0] !== undefined && "context" in suggestions[0]) {
      return normalize(
        generator.filterTemplateSuggestions(suggestions as Fig.TemplateSuggestion[]),
        context.isDangerous,
      );
    }
    return suggestions;
  };
  const results = await cached(
    generator,
    context,
    services,
    generator.cache?.cacheKey,
    // No default directory: the session runs it in the shell's working directory.
    () => custom(context.tokens, services.executeCommand(undefined), figContext(context)),
    (fresh) => onUpdate(filter(fresh)),
  );
  return filter(results);
}

/**
 * Runs one generator. Resolves with its suggestions (empty on any error); `onUpdate` may later
 * receive a newer list when a stale cached value has been revalidated.
 */
export async function runGenerator(
  generator: Fig.Generator,
  context: GeneratorContext,
  services: GeneratorServices,
  onUpdate: Update,
): Promise<GeneratedSuggestion[]> {
  try {
    if (generator.template !== undefined) {
      return normalize(await templateSuggestions(generator, context, services), context.isDangerous);
    }
    if (generator.script !== undefined) {
      return await scriptSuggestions(generator, context, services, onUpdate);
    }
    return await customSuggestions(generator, context, services, onUpdate);
  } catch {
    return [];
  }
}
