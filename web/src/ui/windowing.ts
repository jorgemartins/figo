/** Rows rendered beyond each edge of the viewport so a fast scroll does not show gaps. */
export const OVERSCAN = 2;

/** The [start, end) rows to render for a scroll position. */
export function visibleRange(
  scrollTop: number,
  viewportHeight: number,
  itemSize: number,
  count: number,
  overscan = OVERSCAN,
): [number, number] {
  if (count <= 0 || itemSize <= 0) {
    return [0, 0];
  }
  const first = Math.min(count - 1, Math.max(0, Math.floor(scrollTop / itemSize)));
  const last = Math.min(count - 1, Math.max(first, Math.ceil((scrollTop + viewportHeight) / itemSize) - 1));
  return [Math.max(0, first - overscan), Math.min(count, last + 1 + overscan)];
}

/** Height of the scrolling viewport: as many rows as fit, never more than there are. */
export function viewportHeight(count: number, itemSize: number, available: number): number {
  return Math.max(0, Math.min(count * itemSize, available));
}

/**
 * The scroll offset that brings `index` into view the way react-window's "smart" alignment does:
 * unchanged when the row is fully visible, a minimal scroll when it is within one viewport of the
 * visible area, otherwise the row is centred.
 */
export function smartScrollOffset(
  index: number,
  scrollTop: number,
  viewport: number,
  itemSize: number,
  count: number,
): number {
  const lastOffset = Math.max(0, count * itemSize - viewport);
  const maxOffset = Math.min(lastOffset, index * itemSize);
  const minOffset = Math.max(0, index * itemSize - viewport + itemSize);

  const near = scrollTop >= minOffset - viewport && scrollTop <= maxOffset + viewport;
  if (near) {
    if (scrollTop >= minOffset && scrollTop <= maxOffset) {
      return scrollTop;
    }
    return scrollTop < minOffset ? minOffset : maxOffset;
  }

  const middle = Math.round(minOffset + (maxOffset - minOffset) / 2);
  if (middle < Math.ceil(viewport / 2)) {
    return 0;
  }
  if (middle > lastOffset + Math.floor(viewport / 2)) {
    return lastOffset;
  }
  return middle;
}
