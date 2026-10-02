import { useLayoutEffect, useRef } from "react";
import type { ArgumentInfo, Suggestion } from "../core/contract";
import { footerContent, itemDescription } from "./descriptionText";
import { POPOUT_WIDTH } from "./metrics";

function NoDescription() {
  return <span className="figo-no-description">No description</span>;
}

/** The one-line description under the list, with the hint badge on the right. */
export function DescriptionFooter({
  selected,
  argument,
  hint,
  itemSize,
}: {
  selected: Suggestion | undefined;
  argument: ArgumentInfo | null;
  hint: string | null;
  itemSize: number;
}) {
  const { name, text } = footerContent(selected, argument);
  const textRef = useRef<HTMLSpanElement>(null);

  // The text can be scrolled sideways with a trackpad; a new item starts at its beginning again.
  useLayoutEffect(() => {
    if (textRef.current) {
      textRef.current.scrollLeft = 0;
    }
  }, [selected, argument]);

  return (
    <div className="figo-footer-row">
      <div className="figo-description figo-footer" style={{ height: itemSize }}>
        <span ref={textRef} className="figo-description-text">
          {name && <strong>{name}</strong>}
          {name && text && ": "}
          {name ? text : text || <NoDescription />}
        </span>
        {hint && (
          <div className="figo-hint" style={{ fontSize: itemSize * 0.5 }}>
            <span>{hint}</span>
          </div>
        )}
      </div>
    </div>
  );
}

/** The description beside the list (⌃K), with the hint as a pill in its bottom-right corner. */
export function DescriptionPanel({
  selected,
  hint,
  maxHeight,
}: {
  selected: Suggestion | undefined;
  hint: string | null;
  maxHeight: number;
}) {
  const text = itemDescription(selected);
  return (
    <div className="figo-description figo-panel" style={{ maxHeight, width: POPOUT_WIDTH }}>
      <div className="figo-panel-column" style={{ maxHeight: maxHeight - 10 }}>
        <div className="figo-panel-text">{text ? <span>{text}</span> : <NoDescription />}</div>
        {hint && (
          <div className="figo-hint figo-hint-pill">
            <span>{hint}</span>
          </div>
        )}
      </div>
    </div>
  );
}

/** Shown alone when nothing can be suggested but the argument being typed has a name. */
export function ArgumentHintBox({ argument, itemSize }: { argument: ArgumentInfo; itemSize: number }) {
  const name = argument.name.trim();
  const description = argument.description?.trim() ?? "";
  const stacked = Boolean(name && description);
  return (
    <div className="figo-list-container">
      <div className="figo-footer-row">
        <div className="figo-description figo-argument" style={{ height: stacked ? itemSize * 2 : itemSize }}>
          <span className="figo-description-text">
            <strong>{name}</strong>
            {stacked && ": "}
            {stacked && <br />}
            {description}
          </span>
        </div>
      </div>
    </div>
  );
}
