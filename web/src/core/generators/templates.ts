import type { Annotation } from "../parser/state";
import type { Subcommand } from "../specs/types";
import { makeArray } from "../utils";
import type { GeneratorContext, GeneratorServices } from "./context";

/**
 * The `help` template: the subcommands next to the one that triggered it, e.g. `git help <here>`
 * lists git's other subcommands.
 */
export function helpSuggestions(annotations: readonly Annotation[]): Fig.TemplateSuggestion[] {
  const root = annotations[0];
  if (root?.type !== "subcommand" || root.spec === undefined) {
    return [];
  }
  let trigger: Annotation | undefined;
  for (let i = annotations.length - 1; i >= 0; i -= 1) {
    const annotation = annotations[i];
    if (annotation?.type === "subcommand" || annotation?.type === "option") {
      trigger = annotation;
      break;
    }
  }
  if (trigger === undefined) {
    return [];
  }
  let parent: Subcommand = root.spec;
  let excluded = new Set<string>();
  for (const annotation of annotations.slice(1)) {
    if (annotation.type !== "subcommand") {
      continue;
    }
    const child = parent.subcommands.get(annotation.text);
    if (child === undefined) {
      break;
    }
    if (annotation === trigger) {
      excluded = new Set(child.name);
    } else {
      parent = child;
    }
  }
  return [...parent.subcommands.keys()]
    .filter((name) => !excluded.has(name))
    .map((name) => ({
      type: "special",
      name,
      insertValue: name,
      isDangerous: false,
      context: { templateType: "help" },
    }));
}

export async function templateSuggestions(
  generator: Fig.Generator,
  context: GeneratorContext,
  services: GeneratorServices,
): Promise<Fig.Suggestion[]> {
  const templates = new Set(makeArray(generator.template));
  const suggestions: Fig.TemplateSuggestion[] = [];
  if (templates.has("history")) {
    suggestions.push(...(await services.historyValues(context)));
  }
  if (templates.has("help")) {
    suggestions.push(...helpSuggestions(context.annotations));
  }
  return generator.filterTemplateSuggestions ? generator.filterTemplateSuggestions(suggestions) : suggestions;
}
