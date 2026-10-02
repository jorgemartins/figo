/**
 * Whether a generator must re-run when the argument stays the same but the search term changes
 * (engine doc §5.2). Without a `trigger` it only re-runs for debounced arguments.
 */
export function shouldRetrigger(
  trigger: Fig.Trigger | undefined,
  newSearchTerm: string,
  oldSearchTerm: string,
  debounced: boolean,
): boolean {
  if (trigger === undefined) {
    return debounced;
  }
  try {
    if (typeof trigger === "string") {
      return newSearchTerm.lastIndexOf(trigger) !== oldSearchTerm.lastIndexOf(trigger);
    }
    if (typeof trigger === "function") {
      return Boolean(trigger(newSearchTerm, oldSearchTerm));
    }
    switch (trigger.on) {
      case "threshold":
        // Only when crossing the length upwards, as upstream.
        return newSearchTerm.length > trigger.length && !(oldSearchTerm.length > trigger.length);
      case "match": {
        const strings = typeof trigger.string === "string" ? [trigger.string] : trigger.string;
        return strings.indexOf(newSearchTerm) !== strings.indexOf(oldSearchTerm);
      }
      default:
        return newSearchTerm !== oldSearchTerm;
    }
  } catch {
    return true;
  }
}
