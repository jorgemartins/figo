import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { Core, CoreState, Suggestion } from "../core/contract";
import { Popup } from "./Popup";
import { Row } from "./Row";

function suggestion(names: string[], extra: Partial<Suggestion> = {}): Suggestion {
  return { type: "subcommand", names, match: { nameIndex: 0, ranges: [] }, ...extra };
}

function staticCore(patch: Partial<CoreState>): Core {
  const state: CoreState = {
    sessionId: "s",
    visible: true,
    suggestions: [],
    selectedIndex: 0,
    commonPrefix: null,
    loading: false,
    argument: null,
    historyMode: false,
    descriptionPopout: false,
    scale: 1,
    shakeCount: 0,
    settings: {},
    ...patch,
  };
  return { getState: () => state, subscribe: () => () => {}, dispatch: () => {}, insert: () => {}, dispose: () => {} };
}

const render = (patch: Partial<CoreState>) => renderToStaticMarkup(<Popup core={staticCore(patch)} />);

describe("Row markup", () => {
  it("joins names with a comma and dims the arguments after a space", () => {
    const html = renderToStaticMarkup(
      <Row
        suggestion={suggestion(["install", "i"], {
          args: [{ name: "package", isOptional: true, isVariadic: true }],
          match: { nameIndex: 0, ranges: [[0, 1]] },
        })}
        index={0}
        selected
        top={0}
        itemSize={20}
        iconSize={15}
        underline={null}
        onInsert={() => {}}
      />,
    );
    expect(html).toContain('class="figo-row is-selected"');
    expect(html).toContain('data-active-item="true"');
    expect(html).toContain('<mark class="figo-match"><span>i</span></mark><span>nstall</span><span>, </span><mark class="figo-match"><span>i</span></mark>');
    expect(html).toContain('<span class="figo-args"> [package...] </span>');
  });
});

describe("Popup markup", () => {
  it("renders an empty root when hidden or when there is nothing to show", () => {
    expect(render({ visible: false, suggestions: [suggestion(["a"])] })).toMatch(/^<div class="figo-popup"[^>]*><\/div>$/);
    expect(render({})).toMatch(/^<div class="figo-popup"[^>]*><\/div>$/);
  });

  it("shows only the loader while loading", () => {
    const html = render({ loading: true, suggestions: [suggestion(["a"])] });
    expect(html).toContain("figo-loading");
    expect(html).not.toContain("figo-row");
  });

  it("shows the argument box when there are no suggestions but a named argument", () => {
    const html = render({ argument: { name: "message", description: "The commit message" } });
    expect(html).toContain("<strong>message</strong>: <br/>The commit message");
    expect(html).toContain("height:40px");
  });

  it("renders the list with the footer and hint, windowed to the visible rows", () => {
    const suggestions = Array.from({ length: 40 }, (_, i) => suggestion([`item${i}`], { type: "folder" }));
    const html = render({ suggestions });
    expect(html.match(/class="figo-row( is-selected)?"/g)).toHaveLength(8);
    expect(html).toContain('class="figo-list has-footer" style="height:120px"');
    expect(html).toContain("width:320px;max-height:140px");
    expect(html).toContain('<span class="figo-description-text">folder</span>');
    expect(html).toContain("<span>⌃k</span>");
  });

  it("hides the hint when the side panel is always shown", () => {
    const html = render({ suggestions: [suggestion(["a"])], settings: { "autocomplete.alwaysShowDescription": true } });
    expect(html).not.toContain("⌃k");
    expect(html).toContain("No description");
  });

  it("applies theme variables and the font size", () => {
    const html = render({ suggestions: [suggestion(["a"])], settings: { "autocomplete.theme": "light", "autocomplete.fontSize": 16 } });
    expect(html).toContain("--main-bg-color:254 254 254");
    expect(html).toContain("--rem:16px");
    expect(html).toContain("height:25px");
  });
});
