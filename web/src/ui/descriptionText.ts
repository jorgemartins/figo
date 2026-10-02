import type { ArgumentInfo, Suggestion } from "../core/contract";

export interface FooterContent {
  /** Bold argument name shown before the text, when the text comes from the argument. */
  name: string;
  text: string;
}

/**
 * What the selected item says about itself: its description, or for files and folders without
 * one the bare words "file" / "folder".
 */
export function itemDescription(selected: Suggestion | undefined): string {
  const description = selected?.description?.trim() ?? "";
  if (description) {
    return description;
  }
  return selected && (selected.type === "file" || selected.type === "folder") ? selected.type : "";
}

/**
 * The footer under the list: the item's own description, else the current argument's name and
 * description. Empty name and text render as "No description".
 */
export function footerContent(selected: Suggestion | undefined, argument: ArgumentInfo | null): FooterContent {
  const text = itemDescription(selected);
  if (text) {
    return { name: "", text };
  }
  return { name: argument?.name.trim() ?? "", text: argument?.description?.trim() ?? "" };
}
