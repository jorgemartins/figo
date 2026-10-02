import type { GeneratorContext, GeneratorServices } from "../generators/context";
import { runGenerator } from "../generators/run";
import { shouldRetrigger } from "../generators/trigger";
import type { ParseResult } from "../parser/parse";
import { itemFromGenerated } from "../suggestions/collect";
import type { Item } from "../suggestions/types";

export interface GeneratorRun {
  /** Identifies the run, so a result that arrives after its argument changed is dropped. */
  id: number;
  generator: Fig.Generator;
  context: GeneratorContext;
  loading: boolean;
  /** Needed but not started: generators only run while the popup is to be shown (`start`). */
  pending: boolean;
  result: Item[];
}

const DEFAULT_DEBOUNCE_MS = 200;

/** The generators of the current argument, their results, and whether any is still running. */
export class GeneratorRuns {
  private runs: GeneratorRun[] = [];
  private nextId = 1;
  /** The current argument's `debounce`; every run belongs to that argument. */
  private debounce: unknown;

  constructor(
    private readonly services: () => GeneratorServices,
    private readonly onChange: () => void,
    /**
     * Whether generators may run now (the popup is to be shown). Checked again when a run starts
     * after its debounce and before each command a generator issues.
     */
    private readonly mayRun: () => boolean = () => true,
  ) {}

  get current(): readonly GeneratorRun[] {
    return this.runs;
  }

  get loading(): boolean {
    return this.runs.some((run) => run.loading);
  }

  /** Some generator of the current argument still has to run before the list is complete. */
  get pending(): boolean {
    return this.runs.some((run) => run.pending);
  }

  clear(): void {
    this.runs = [];
  }

  /**
   * Works out what the new parse needs (engine doc §5.2): every generator of a new argument, and
   * generators whose trigger fires for the new search term. Those runs wait for `start`. Returns
   * the runs it replaced.
   */
  update(result: ParseResult, previous: ParseResult | null, context: GeneratorContext): readonly GeneratorRun[] {
    const arg = result.currentArg;
    const old = this.runs;
    const sameArg = previous !== null && arg === previous.currentArg;
    this.debounce = arg?.debounce;
    this.runs = (arg?.generators ?? []).map((generator, index) => {
      const before = old[index];
      const rerun =
        before === undefined ||
        !sameArg ||
        shouldRetrigger(generator.trigger, result.searchTerm, previous?.searchTerm ?? "", Boolean(arg?.debounce));
      if (!rerun && before !== undefined) {
        // One that never started runs with the line as it is when it does (`lookup abc`, not the
        // `lookup ` it was planned for).
        return before.pending ? { ...before, context } : before;
      }
      return {
        id: this.nextId++,
        generator,
        context,
        loading: false,
        pending: true,
        // Only a generator's own earlier results are kept (upstream briefly showed another argument's).
        result: before !== undefined && before.generator === generator ? before.result : [],
      };
    });
    return old;
  }

  /** Starts every run that is waiting; true when there was one. */
  start(): boolean {
    const waiting = this.runs.filter((run) => run.pending);
    if (waiting.length === 0) {
      return false;
    }
    this.runs = this.runs.map((run) => (run.pending ? { ...run, pending: false, loading: true } : run));
    const debounce = this.debounce;
    for (const { id } of waiting) {
      if (debounce) {
        setTimeout(() => this.run(id), typeof debounce === "number" && debounce > 0 ? debounce : DEFAULT_DEBOUNCE_MS);
      } else {
        queueMicrotask(() => this.run(id));
      }
    }
    return true;
  }

  /**
   * The popup was hidden: runs that have not finished are dropped (their results, and any command
   * they would still issue, are ignored) and wait to be started again. True when there was one.
   */
  pause(): boolean {
    if (!this.loading) {
      return false;
    }
    this.runs = this.runs.map((run) => (run.loading ? this.requeued(run) : run));
    return true;
  }

  /** Whether a run of `generator` in `old` was replaced by the last update. */
  replaced(old: readonly GeneratorRun[], generator: Fig.Generator | undefined): boolean {
    return (
      generator !== undefined && old.some((run, index) => run.generator === generator && this.runs[index]?.id !== run.id)
    );
  }

  private requeued(run: GeneratorRun): GeneratorRun {
    return { ...run, id: this.nextId++, loading: false, pending: true };
  }

  private run(id: number): void {
    const run = this.runs.find((candidate) => candidate.id === id);
    if (run === undefined) {
      return; // superseded or paused during the debounce
    }
    if (!this.mayRun()) {
      this.requeue(id);
      return;
    }
    const services = this.services();
    let refused = false;
    const guarded: GeneratorServices = {
      ...services,
      executeCommand: (cwd, timeoutMs) => {
        const execute = services.executeCommand(cwd, timeoutMs);
        return (input) => {
          if (!this.mayRun()) {
            refused = true;
            return Promise.reject(new Error("The popup is hidden"));
          }
          return execute(input);
        };
      },
    };
    void runGenerator(run.generator, run.context, guarded, (late) => this.finish(id, late)).then((results) =>
      refused ? this.requeue(id) : this.finish(id, results),
    );
  }

  /** A run that could not go on while the popup is hidden waits to be started again. */
  private requeue(id: number): void {
    if (this.runs.some((run) => run.id === id)) {
      this.runs = this.runs.map((run) => (run.id === id ? this.requeued(run) : run));
      this.onChange();
    }
  }

  private finish(id: number, results: Fig.Suggestion[]): void {
    const run = this.runs.find((candidate) => candidate.id === id);
    if (run === undefined) {
      return; // the argument changed meanwhile
    }
    const isDangerous = run.context.isDangerous;
    const items = results
      .map((suggestion) => itemFromGenerated(suggestion, { generator: run.generator, isDangerous }))
      .filter((item): item is Item => item !== null);
    this.runs = this.runs.map((candidate) =>
      candidate.id === id ? { ...candidate, loading: false, result: items } : candidate,
    );
    this.onChange();
  }
}
