import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { smartScrollOffset, visibleRange } from "./windowing";

export interface VirtualListProps {
  count: number;
  itemSize: number;
  /** Viewport height; rows beyond it scroll (with a hidden scrollbar). */
  height: number;
  selectedIndex: number;
  /** A new value (a new list) brings the selection back into view even if its index is unchanged. */
  revision: unknown;
  className: string;
  renderRow: (index: number, top: number) => ReactNode;
}

/**
 * A fixed-row-height windowed list: only the rows in (or near) the viewport are mounted. The
 * selection is scrolled into view with react-window's "smart" alignment, without animation.
 */
export function VirtualList({ count, itemSize, height, selectedIndex, revision, className, renderRow }: VirtualListProps) {
  const ref = useRef<HTMLDivElement>(null);
  const [scrollTop, setScrollTop] = useState(0);

  useLayoutEffect(() => {
    const element = ref.current;
    if (!element || count === 0) {
      return;
    }
    const target = smartScrollOffset(selectedIndex, element.scrollTop, height, itemSize, count);
    if (target !== element.scrollTop) {
      element.scrollTop = target;
    }
    // The browser clamps the offset when the list got shorter, so read back what it kept.
    setScrollTop(element.scrollTop);
  }, [selectedIndex, height, itemSize, count, revision]);

  const [start, end] = visibleRange(scrollTop, height, itemSize, count);
  const rows: ReactNode[] = [];
  for (let index = start; index < end; index += 1) {
    rows.push(renderRow(index, index * itemSize));
  }

  return (
    <div ref={ref} className={className} style={{ height }} onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}>
      <div className="figo-list-content" style={{ height: count * itemSize }}>
        {rows}
      </div>
    </div>
  );
}
