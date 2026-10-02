import type { CreateCore } from "./contract";
import { CompletionCore } from "./state/core";

export type * from "./contract";

export const createCore: CreateCore = (bridge, options) => new CompletionCore(bridge, options);
