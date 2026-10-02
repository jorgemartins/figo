import { Fragment, memo } from "react";
import type { Suggestion } from "../core/contract";
import { SuggestionIcon } from "./icons/Icon";
import { argumentText, titleSegments, type PrefixUnderline, type Segment } from "./title";

function SegmentView({ segment }: { segment: Segment }) {
  switch (segment.kind) {
    case "match":
      return (
        <mark className="figo-match">
          <span>{segment.text}</span>
        </mark>
      );
    case "prefix":
      return <mark className="figo-prefix">{segment.text}</mark>;
    default:
      return <span>{segment.text}</span>;
  }
}

export interface RowProps {
  suggestion: Suggestion;
  index: number;
  selected: boolean;
  top: number;
  itemSize: number;
  iconSize: number;
  underline: PrefixUnderline | null;
  onInsert: (index: number) => void;
}

export const Row = memo(function Row({ suggestion, index, selected, top, itemSize, iconSize, underline, onInsert }: RowProps) {
  const names = titleSegments(suggestion, underline);
  const args = argumentText(suggestion.args);
  return (
    <div
      className={selected ? "figo-row is-selected" : "figo-row"}
      style={{ top, height: itemSize }}
      onClick={() => onInsert(index)}
    >
      <SuggestionIcon suggestion={suggestion} size={iconSize} />
      <div className="figo-row-clip">
        <div className="figo-text figo-row-text" data-active-item={selected ? true : undefined}>
          {names.map((segments, nameIndex) => (
            <Fragment key={nameIndex}>
              {nameIndex > 0 && <span>, </span>}
              {segments.map((segment, segmentIndex) => (
                <SegmentView key={segmentIndex} segment={segment} />
              ))}
            </Fragment>
          ))}
          {args && <span className="figo-args"> {args} </span>}
        </div>
      </div>
    </div>
  );
});
