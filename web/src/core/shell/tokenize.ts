/**
 * A small shell lexer: enough of bash/zsh/fish syntax to find the simple command the cursor is in
 * and split it into words the way the shell would.
 *
 * The buffer is always cut at the cursor first, so "the command under the cursor" is the command
 * still open at the end of the input. Nested contexts (`$(…)`, backticks, `(…)`, `{ …; }`,
 * `<(…)`) are scanned recursively and the innermost command reaching the end wins, so
 * `echo $(git ch` completes `git`.
 */

export interface Token {
  /** The word as the shell sees it: quotes and escapes removed, expansions kept literally. */
  text: string;
  /** [start, end) of the word in the buffer, in UTF-16 units. */
  start: number;
  end: number;
  /**
   * `offsets[i]` is where the source of `text[i]` starts in the buffer (the backslash of an escape,
   * the character itself otherwise); `offsets[text.length]` is `end`. Insertion uses this to delete
   * exactly what the user typed, quotes and escapes included.
   */
  offsets: number[];
  /** False when the word ends inside an unterminated quote or substitution. */
  complete: boolean;
}

export interface Command {
  tokens: Token[];
  /** The last token is the target of a redirection (`cat x > fi`), not an argument. */
  redirectTarget: boolean;
}

const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=/;
const REDIRECT = /^(?:&>>|&>|\d*(?:>>|>&|>\||<<<|<<-|<<|<&|<>|>|<))/;
const TWO_CHAR_OPERATORS = new Set(["&&", "||", "|&", ";;", "&;", ";&"]);

type LastItem = "none" | "word" | "assignment" | "redirect" | "target";

class Scanner {
  pos = 0;
  /** The command reaching the end of the input; the first one found is the innermost. */
  active: Command | null = null;
  activeFound = false;
  inComment = false;
  /** Statements at the outermost level, to recognise single-command alias values. */
  topLevelStatements = 0;
  readonly finished: Command[] = [];

  constructor(private readonly src: string) {}

  get eof(): boolean {
    return this.pos >= this.src.length;
  }

  peek(offset = 0): string {
    return this.src.charAt(this.pos + offset);
  }

  skipBlanks(): void {
    while (!this.eof) {
      const c = this.peek();
      if (c === " " || c === "\t") {
        this.pos += 1;
      } else if (c === "\\" && this.peek(1) === "\n") {
        this.pos += 2;
      } else {
        break;
      }
    }
  }

  /** Scans statements up to `closer` (consumed) or the end of input; true if the closer was found. */
  parseList(closer: string | null): boolean {
    for (;;) {
      if (closer === null) {
        this.topLevelStatements += 1;
      }
      this.parseStatement(closer);
      if (this.eof) {
        return false;
      }
      const c = this.peek();
      if (closer !== null && c === closer) {
        this.pos += 1;
        return true;
      }
      if (c === "\n" || c === ";" || c === "&" || c === "|") {
        this.pos += TWO_CHAR_OPERATORS.has(this.src.slice(this.pos, this.pos + 2)) ? 2 : 1;
        continue;
      }
      // Something no statement can start with (text after a closed subshell, a stray closer):
      // step over it so scanning always advances.
      this.pos += 1;
    }
  }

  private parseStatement(closer: string | null): void {
    const statementStart = this.pos;
    this.skipBlanks();
    if (this.peek() === "!" && /[ \t]/.test(this.peek(1))) {
      this.pos += 1;
      this.skipBlanks();
    }
    const c = this.peek();
    if (c === "(") {
      this.pos += 1;
      this.parseList(")");
      return;
    }
    if (c === "{" && /[ \t\n]/.test(this.peek(1))) {
      this.pos += 1;
      this.parseList("}");
      return;
    }
    this.parseCommand(closer, statementStart);
  }

  private parseCommand(closer: string | null, statementStart: number): void {
    const tokens: Token[] = [];
    let last: LastItem = "none";
    let lastEnd = statementStart;
    let pendingRedirect = false;
    let target: Token | null = null;

    for (;;) {
      this.skipBlanks();
      if (this.eof) {
        break;
      }
      const redirect = this.matchRedirect();
      if (redirect !== null) {
        this.pos += redirect.length;
        if (/[<>]&$/.test(redirect) && /[0-9-]/.test(this.peek())) {
          // `2>&1`, `>&-`: duplicating a descriptor takes no file name.
          while (!this.eof && /[0-9-]/.test(this.peek())) {
            this.pos += 1;
          }
          last = "redirect";
        } else {
          pendingRedirect = true;
          last = "redirect";
        }
        lastEnd = this.pos;
        continue;
      }
      const c = this.peek();
      if (c === "\n" || c === ";" || c === "&" || c === "|") {
        break;
      }
      if (closer !== null && c === closer) {
        break;
      }
      if (c === "#") {
        while (!this.eof && this.peek() !== "\n") {
          this.pos += 1;
        }
        if (this.eof) {
          this.inComment = true;
        }
        continue;
      }
      const word = this.parseWord(closer);
      lastEnd = word.end;
      if (pendingRedirect) {
        pendingRedirect = false;
        target = word;
        last = "target";
        continue;
      }
      if (tokens.length === 0 && ASSIGNMENT.test(this.src.slice(word.start, word.end))) {
        last = "assignment";
        continue;
      }
      tokens.push(word);
      last = "word";
    }

    if (!this.eof) {
      this.finished.push({ tokens, redirectTarget: false });
      return;
    }
    if (this.activeFound || this.inComment) {
      return;
    }
    this.activeFound = true;

    const end = this.src.length;
    const endsWithSpace = lastEnd < end && this.src.endsWith(" ");
    if (pendingRedirect) {
      // `cat x >` or `cat x > `: the file name is being typed.
      this.active = { tokens: [...tokens, emptyToken(end)], redirectTarget: true };
    } else if (last === "target" && !endsWithSpace && target !== null) {
      this.active = { tokens: [...tokens, target], redirectTarget: true };
    } else if (endsWithSpace) {
      this.active = { tokens: [...tokens, emptyToken(end)], redirectTarget: false };
    } else if (last === "word") {
      this.active = { tokens, redirectTarget: false };
    } else {
      // The cursor is right after an assignment or a descriptor redirection: nothing to complete.
      this.active = { tokens: [], redirectTarget: false };
    }
  }

  private matchRedirect(): string | null {
    const rest = this.src.slice(this.pos, this.pos + 8);
    if (/^\d*[<>]\(/.test(rest)) {
      return null; // process substitution, scanned as a word
    }
    const match = REDIRECT.exec(rest);
    return match ? match[0] : null;
  }

  private parseWord(closer: string | null): Token {
    const start = this.pos;
    const word = { text: "", offsets: [] as number[], complete: true };
    const push = (char: string, at: number) => {
      word.text += char;
      word.offsets.push(at);
    };
    const pushSource = (from: number, to: number) => {
      for (let i = from; i < to; i += 1) {
        push(this.src.charAt(i), i);
      }
    };

    while (!this.eof) {
      const c = this.peek();
      if (c === " " || c === "\t" || c === "\n" || c === ";" || c === "&" || c === "|") {
        break;
      }
      if (c === "<" || c === ">") {
        if (this.peek(1) !== "(") {
          break;
        }
        const from = this.pos;
        this.pos += 2;
        if (!this.parseList(")")) {
          word.complete = false;
        }
        pushSource(from, this.pos);
        continue;
      }
      if ((closer === ")" || closer === "`") && c === closer) {
        break;
      }
      if (c === "\\") {
        const next = this.peek(1);
        if (next === "\n") {
          this.pos += 2;
        } else if (next === "") {
          this.pos += 1;
        } else {
          push(next, this.pos);
          this.pos += 2;
        }
        continue;
      }
      if (c === "'") {
        this.pos += 1;
        while (!this.eof && this.peek() !== "'") {
          push(this.peek(), this.pos);
          this.pos += 1;
        }
        if (this.eof) {
          word.complete = false;
        } else {
          this.pos += 1;
        }
        continue;
      }
      if (c === '"') {
        this.pos += 1;
        if (!this.scanDoubleQuoted(push, pushSource)) {
          word.complete = false;
        }
        continue;
      }
      if (c === "$" || c === "`") {
        if (!this.scanExpansion(false, pushSource)) {
          word.complete = false;
        }
        continue;
      }
      push(c, this.pos);
      this.pos += 1;
    }
    word.offsets.push(this.pos);
    return { text: word.text, start, end: this.pos, offsets: word.offsets, complete: word.complete };
  }

  /** Scans the inside of `"…"` after the opening quote; false if it is unterminated. */
  private scanDoubleQuoted(
    push: (char: string, at: number) => void,
    pushSource: (from: number, to: number) => void,
  ): boolean {
    while (!this.eof) {
      const c = this.peek();
      if (c === '"') {
        this.pos += 1;
        return true;
      }
      if (c === "\\" && '$`"\\\n'.includes(this.peek(1)) && this.peek(1) !== "") {
        if (this.peek(1) !== "\n") {
          push(this.peek(1), this.pos);
        }
        this.pos += 2;
        continue;
      }
      if (c === "$" || c === "`") {
        if (!this.scanExpansion(true, pushSource)) {
          return false;
        }
        continue;
      }
      push(c, this.pos);
      this.pos += 1;
    }
    return false;
  }

  /**
   * Scans `$…` or a backtick substitution at the cursor and keeps its source text literally (the
   * shell would expand it; completion only needs to know where it ends). Command substitutions
   * are scanned as nested lists so a command inside them can be the one being completed.
   */
  private scanExpansion(inString: boolean, pushSource: (from: number, to: number) => void): boolean {
    const from = this.pos;
    let complete = true;
    if (this.peek() === "`") {
      this.pos += 1;
      complete = this.parseList("`");
    } else if (this.peek(1) === "(" && this.peek(2) === "(") {
      this.pos += 3;
      complete = this.skipBalanced("(", ")", 2);
    } else if (this.peek(1) === "(") {
      this.pos += 2;
      complete = this.parseList(")");
    } else if (this.peek(1) === "{") {
      this.pos += 2;
      complete = this.skipBalanced("{", "}", 1);
    } else if (this.peek(1) === "'" && !inString) {
      this.pos += 2;
      complete = false;
      while (!this.eof) {
        const c = this.peek();
        if (c === "\\") {
          this.pos += 2;
        } else if (c === "'") {
          this.pos += 1;
          complete = true;
          break;
        } else {
          this.pos += 1;
        }
      }
      this.pos = Math.min(this.pos, this.src.length);
    } else {
      this.pos += 1;
      if (/[*@?#$!0-9_-]/.test(this.peek())) {
        this.pos += 1;
      } else {
        while (!this.eof && /[A-Za-z0-9_]/.test(this.peek())) {
          this.pos += 1;
        }
      }
    }
    pushSource(from, this.pos);
    return complete;
  }

  /** Skips to the closer that brings `depth` back to zero; false at the end of input. */
  private skipBalanced(open: string, close: string, depth: number): boolean {
    let level = depth;
    while (!this.eof) {
      const c = this.peek();
      this.pos += c === "\\" ? 2 : 1;
      if (c === open) {
        level += 1;
      } else if (c === close) {
        level -= 1;
        if (level === 0) {
          return true;
        }
      }
    }
    this.pos = Math.min(this.pos, this.src.length);
    return false;
  }
}

function emptyToken(at: number): Token {
  return { text: "", start: at, end: at, offsets: [at], complete: true };
}

/**
 * The simple command that the end of `buffer` is in, or null when there is nothing to complete
 * there (empty input, inside a comment, right after an operator without a space, …).
 */
export function getCommand(buffer: string): Command | null {
  const scanner = new Scanner(buffer);
  scanner.parseList(null);
  if (scanner.inComment || scanner.active === null || scanner.active.tokens.length === 0) {
    return null;
  }
  return scanner.active;
}

/** Every simple command in a full command line, e.g. one history entry. */
export function splitCommands(line: string): Command[] {
  const scanner = new Scanner(line);
  scanner.parseList(null);
  const commands = [...scanner.finished];
  if (scanner.active !== null && !scanner.inComment) {
    const { tokens, redirectTarget } = scanner.active;
    // Drop the synthetic empty token a trailing space adds; real empty words (`""`) have a width.
    const words = (redirectTarget ? tokens.slice(0, -1) : tokens).filter((token) => token.end > token.start);
    commands.push({ tokens: words, redirectTarget: false });
  }
  return commands.filter((command) => command.tokens.length > 0);
}

/**
 * The words of `text` if it is exactly one complete simple command (no operators, no open
 * quotes), as needed to substitute an alias value; otherwise null.
 */
export function wordsOfSimpleCommand(text: string): Token[] | null {
  const scanner = new Scanner(text.replace(/\s+$/, ""));
  scanner.parseList(null);
  if (scanner.topLevelStatements !== 1 || scanner.inComment || scanner.active === null) {
    return null;
  }
  const { tokens, redirectTarget } = scanner.active;
  if (redirectTarget || tokens.length === 0 || tokens.some((token) => !token.complete)) {
    return null;
  }
  return tokens;
}

/**
 * Where to start deleting when replacing `token` from its inner index `innerIndex` on: the source
 * of that character, moved back over opening quotes directly before it so they are replaced too.
 */
export function sourceStartOf(token: Token, innerIndex: number, buffer: string): number {
  if (innerIndex <= 0) {
    return token.start;
  }
  let at = token.offsets[innerIndex] ?? token.end;
  const sources = new Set(token.offsets.slice(0, innerIndex));
  while (at > token.start) {
    const before = buffer.charAt(at - 1);
    const escaped = buffer.charAt(at - 2) === "\\" && sources.has(at - 2);
    if ((before === '"' || before === "'") && !sources.has(at - 1) && !escaped) {
      at -= 1;
    } else {
      break;
    }
  }
  return at;
}
