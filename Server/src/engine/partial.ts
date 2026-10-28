// An answer read as it streams in, as FoundationModels reads a model's text into GeneratedContent
// for the app (GeneratedContent(json:)): JSON that may stop anywhere. Whatever has arrived is kept:
// a string cut off mid-way is kept as far as it goes, a number as far as it reads, and a list or an
// object closed where it stopped; a property whose name or value hasn't begun is left out. A word
// cut off (`tru`) makes the whole text unreadable for now, as it does for the app, so the page
// stays as it was until more arrives.

type JSONValue = string | number | boolean | null | JSONValue[] | { [key: string]: JSONValue };

class Unreadable extends Error {}

/** Nothing there yet: the text ended before this value began. */
const ABSENT = Symbol("absent");

/** The text so far as JSON, or null while it can't be read. */
export function parsePartial(text: string): JSONValue | null {
  const reader = new Reader(text);
  try {
    reader.space();
    const value = reader.value();
    if (value === ABSENT) return null;
    reader.space();
    if (!reader.atEnd) return null;
    return value;
  } catch (error) {
    if (error instanceof Unreadable) return null;
    throw error;
  }
}

function set(object: { [key: string]: JSONValue }, key: string, value: JSONValue) {
  // The first of two properties with one name is kept, and a name like __proto__ is only a name.
  if (Object.prototype.hasOwnProperty.call(object, key)) return;
  Object.defineProperty(object, key, { value, enumerable: true, writable: true, configurable: true });
}

class Reader {
  private readonly text: string;
  private at = 0;

  constructor(text: string) {
    this.text = text;
  }

  get atEnd(): boolean {
    return this.at >= this.text.length;
  }

  space() {
    while (!this.atEnd && " \t\n\r".includes(this.text[this.at])) this.at++;
  }

  value(): JSONValue | typeof ABSENT {
    if (this.atEnd) return ABSENT;
    const character = this.text[this.at];
    if (character === "{") return this.object();
    if (character === "[") return this.array();
    if (character === '"') return this.string();
    if (character === "-" || (character >= "0" && character <= "9")) return this.number();
    for (const [word, value] of [["true", true], ["false", false], ["null", null]] as const) {
      if (this.text.startsWith(word, this.at)) {
        this.at += word.length;
        return value;
      }
    }
    throw new Unreadable();
  }

  private object(): JSONValue {
    this.at++;
    const result: { [key: string]: JSONValue } = {};
    while (true) {
      this.space();
      if (this.atEnd) return result;
      if (this.text[this.at] === "}") {
        this.at++;
        return result;
      }
      if (this.text[this.at] !== '"') throw new Unreadable();
      const key = this.string(true);
      if (key === ABSENT) return result;
      this.space();
      if (this.atEnd) return result;
      if (this.text[this.at] !== ":") throw new Unreadable();
      this.at++;
      this.space();
      const value = this.value();
      if (value === ABSENT) return result;
      set(result, key, value);
      this.space();
      if (this.atEnd) return result;
      const next = this.text[this.at];
      this.at++;
      if (next === "}") return result;
      if (next !== ",") throw new Unreadable();
    }
  }

  private array(): JSONValue {
    this.at++;
    const result: JSONValue[] = [];
    while (true) {
      this.space();
      if (this.atEnd) return result;
      if (this.text[this.at] === "]") {
        this.at++;
        return result;
      }
      const value = this.value();
      if (value === ABSENT) return result;
      result.push(value);
      this.space();
      if (this.atEnd) return result;
      const next = this.text[this.at];
      this.at++;
      if (next === "]") return result;
      if (next !== ",") throw new Unreadable();
    }
  }

  /** A string, or as much of one as there is. A name cut off is no name at all. */
  private string(isKey = false): string | typeof ABSENT {
    this.at++;
    let result = "";
    while (true) {
      if (this.atEnd) return isKey ? ABSENT : result;
      const character = this.text[this.at];
      if (character === '"') {
        this.at++;
        return result;
      }
      if (character < " ") throw new Unreadable();
      if (character !== "\\") {
        result += character;
        this.at++;
        continue;
      }
      // An escape cut off is left out.
      const escape = this.text[this.at + 1];
      if (escape === undefined) return isKey ? ABSENT : result;
      const simple: Record<string, string> = { '"': '"', "\\": "\\", "/": "/", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t" };
      if (escape in simple) {
        result += simple[escape];
        this.at += 2;
        continue;
      }
      if (escape !== "u") throw new Unreadable();
      const hex = this.text.slice(this.at + 2, this.at + 6);
      if (hex.length < 4) {
        if (!/^[0-9A-Fa-f]*$/.test(hex)) throw new Unreadable();
        return isKey ? ABSENT : result;
      }
      if (!/^[0-9A-Fa-f]{4}$/.test(hex)) throw new Unreadable();
      const code = parseInt(hex, 16);
      this.at += 6;
      if (code >= 0xd800 && code <= 0xdbff) {
        // A surrogate pair is one character; half of one isn't a character at all.
        const low = this.text.slice(this.at, this.at + 6);
        if (!/^\\u[dD][c-fC-F][0-9A-Fa-f]{2}$/.test(low)) throw new Unreadable();
        result += String.fromCharCode(code, parseInt(low.slice(2), 16));
        this.at += 6;
        continue;
      }
      if (code >= 0xdc00 && code <= 0xdfff) throw new Unreadable();
      result += String.fromCharCode(code);
    }
  }

  /** A number, or as much of one as reads: 1. is 1, 1e is 1, and a lone minus is nothing yet. */
  private number(): number | typeof ABSENT {
    const match = this.text.slice(this.at).match(/^-?(?:0|[1-9]\d*)?(?:\.\d*)?(?:[eE][+-]?\d*)?/);
    const written = match ? match[0] : "";
    const next = this.text[this.at + written.length];
    if (next !== undefined && next >= "0" && next <= "9") throw new Unreadable();
    this.at += written.length;
    const readable = written.match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/)?.[0];
    if (readable === undefined || readable === "") {
      if (this.atEnd) return ABSENT;
      throw new Unreadable();
    }
    if (readable.length !== written.length && !this.atEnd) throw new Unreadable();
    return Number(readable);
  }
}
