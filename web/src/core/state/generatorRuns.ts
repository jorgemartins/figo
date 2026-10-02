import type { GeneratorContext, GeneratorServices } from "../generators/context";
import { runGenerator } from "../generators/run";
import { shouldRetrigger } from "../generators/trigger";
import type { ParseResult } from "../parser/parse";
import { itemFromSuggestion } from "../suggestions/collect";
import type { Item } from "../suggestions/types";

export interface GeneratorRun {
  /** Identifies the run, so a result that arrives after its argument changed is dropped. */
  id: number;
  generator: Fig.Generator;
  context: GeneratorContext;
  loading: boolean;
  result: Item[];
}

const DEFAULT_DEBOUNCE_MS = 200;

/** The generators of the current argument, their results, and whether any is still running. */
export class GeneratorRuns {
  private runs: GeneratorRun[] = [];
  private nextId = 1;

  constructor(
    private readonly services: () => GeneratorServices,
    private readonly onChange: () => void,
  ) {}

  get current(): readonly GeneratorRun[] {
    return this.runs;
  }

  get loading(): boolean {
    return this.runs.some((run) => run.loading);
  }

  clear(): void {
    this.runs = [];
  }

  /**
   * Runs what the new parse needs (engine doc §5.2): every generator of a new argument, and
   * generators whose trigger fires for the new search term. Returns the runs it replaced.
   */
  update(result: ParseResult, previous: ParseResult | null, context: GeneratorContext): readonly GeneratorRun[] {
    const arg = result.currentArg;
    const old = this.runs;
    const sameArg = previous !== null && arg === previous.currentArg;
    this.runs = (arg?.generators ?? []).map((generator, index) => {
      const before = old[index];
      const rerun =
        before === undefined ||
        !sameArg ||
        shouldRetrigger(generator.trigger, result.searchTerm, previous?.searchTerm ?? "", Boolean(arg?.debounce));
      if (!rerun && before !== undefined) {
        return before;
      }
      const run: GeneratorRun = {
        id: this.nextId++,
        generator,
        context,
        loading: true,
        // Only a generator's own earlier results are kept (upstream briefly showed another argument's).
        result: before !== undefined && before.generator === generator ? before.result : [],
      };
      const debounce = arg?.debounce;
      if (debounce) {
        setTimeout(
          () => this.start(run.id),
          typeof debounce === "number" && debounce > 0 ? debounce : DEFAULT_DEBOUNCE_MS,
        );
      } else {
        queueMicrotask(() => this.start(run.id));
      }
      return run;
    });
    return old;
  }

  /** Whether a run of `generator` in `old` was replaced by the last update. */
  replaced(old: readonly GeneratorRun[], generator: Fig.Generator | undefined): boolean {
    return generator !== undefined && old.some((run, index) => run.generator === generator && this.runs[index] !== run);
  }

  private start(id: number): void {
    const run = this.runs.find((candidate) => candidate.id === id);
    if (run === undefined) {
      return; // superseded during the debounce
    }
    void runGenerator(run.generator, run.context, this.services(), (late) => this.finish(id, late)).then((results) =>
      this.finish(id, results),
    );
  }

  private finish(id: number, results: Fig.Suggestion[]): void {
    const run = this.runs.find((candidate) => candidate.id === id);
    if (run === undefined) {
      return; // the argument changed meanwhile
    }
    const items = results
      .map((suggestion) => itemFromSuggestion(suggestion, { type: "arg", generator: run.generator }))
      .filter((item): item is Item => item !== null);
    this.runs = this.runs.map((candidate) =>
      candidate.id === id ? { ...candidate, loading: false, result: items } : candidate,
    );
    this.onChange();
  }
}
