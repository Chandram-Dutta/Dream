// The page while it streams: JSON that isn't finished yet, read as far as it goes. On the phone,
// Foundation Models turns each streamed snapshot into a partly generated WireSurface; this is the
// server's way to the same thing (docs/ServerGeneration.md).
//
// What counts, as there: a string as far as it's written, an array's items so far, an object's
// properties whose names are finished and whose values have begun. A number counts as far as it
// reads ("12." is 12), a true, false or null only once it's whole. Then `fitted` holds the value
// to the schema the model writes to, as the app's decoding does: an enum's value that isn't one
// of its cases (yet) is left out, like a block whose kind so far is "hea".
//
// No imports, so test/compose.mjs runs it in Node.

type JSONObject = Record<string, unknown>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

/** Nothing usable yet: a name with no value, a number that's only a sign, "tru". */
const MISSING = Symbol("missing");

class Malformed extends Error {}

/** As much of a JSON value as `text` holds so far, and whether it's whole. Null when it isn't
 * JSON at all, even unfinished, or holds nothing yet. */
export function readPartial(text: string): { value: unknown; complete: boolean } | null {
  let at = 0;
  const end = text.length;
  const blank = () => {
    while (at < end && (text[at] === " " || text[at] === "\n" || text[at] === "\r" || text[at] === "\t")) at++;
  };

  // Each reader returns [value, whole]: MISSING when nothing usable came before the text ran out.
  const value = (): [unknown, boolean] => {
    blank();
    if (at >= end) return [MISSING, false];
    const char = text[at];
    if (char === "{") return object();
    if (char === "[") return array();
    if (char === '"') return string();
    if (char === "-" || (char >= "0" && char <= "9")) return number();
    for (const [word, meaning] of [["true", true], ["false", false], ["null", null]] as const) {
      if (text.startsWith(word, at)) {
        at += word.length;
        return [meaning, true];
      }
      if (word.startsWith(text.slice(at))) {
        at = end;
        return [MISSING, false];
      }
    }
    throw new Malformed();
  };

  const string = (): [string, boolean] => {
    at++; // the opening quote
    let out = "";
    while (at < end) {
      const char = text[at];
      if (char === '"') {
        at++;
        return [out, true];
      }
      if (char !== "\\") {
        out += char;
        at++;
        continue;
      }
      // An escape cut off partway is left out until the rest arrives.
      if (at + 1 >= end) {
        at = end;
        break;
      }
      const code = text[at + 1];
      const simple: Record<string, string> = { '"': '"', "\\": "\\", "/": "/", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t" };
      if (code in simple) {
        out += simple[code];
        at += 2;
        continue;
      }
      if (code !== "u") throw new Malformed();
      const hex = text.slice(at + 2, at + 6);
      if (hex.length < 4) {
        at = end;
        break;
      }
      if (!/^[0-9a-fA-F]{4}$/.test(hex)) throw new Malformed();
      const unit = parseInt(hex, 16);
      // Half of a surrogate pair waits for the other half.
      if (unit >= 0xd800 && unit <= 0xdbff) {
        const low = text.slice(at + 6, at + 12);
        if (low.length < 6) {
          at = end;
          break;
        }
        if (/^\\u[dD][c-fC-F][0-9a-fA-F]{2}$/.test(low)) {
          out += String.fromCharCode(unit, parseInt(low.slice(2), 16));
          at += 12;
          continue;
        }
      }
      out += String.fromCharCode(unit);
      at += 6;
    }
    return [out, false];
  };

  const number = (): [unknown, boolean] => {
    const match = /^-?(0|[1-9]\d*)?(\.\d*)?([eE][+-]?\d*)?/.exec(text.slice(at, at + 64))!;
    const written = match[0];
    at += written.length;
    const whole = at < end;
    // What's there reads as a number once its dangling sign, point or exponent is set aside.
    const readable = written.replace(/[eE][+-]?$/, "").replace(/\.$/, "");
    if (!/\d/.test(readable)) {
      if (whole) throw new Malformed();
      return [MISSING, false];
    }
    const parsed = Number(readable);
    if (!Number.isFinite(parsed)) throw new Malformed();
    return [parsed, whole && written === readable];
  };

  const array = (): [unknown[], boolean] => {
    at++;
    const items: unknown[] = [];
    blank();
    if (text[at] === "]") {
      at++;
      return [items, true];
    }
    for (;;) {
      const [item, whole] = value();
      if (item !== MISSING) items.push(item);
      if (!whole) return [items, false];
      blank();
      if (at >= end) return [items, false];
      if (text[at] === ",") {
        at++;
        continue;
      }
      if (text[at] === "]") {
        at++;
        return [items, true];
      }
      throw new Malformed();
    }
  };

  const object = (): [JSONObject, boolean] => {
    at++;
    const out: JSONObject = {};
    blank();
    if (text[at] === "}") {
      at++;
      return [out, true];
    }
    for (;;) {
      blank();
      if (at >= end) return [out, false];
      if (text[at] !== '"') throw new Malformed();
      const [name, named] = string();
      if (!named) return [out, false];
      blank();
      if (at >= end) return [out, false];
      if (text[at] !== ":") throw new Malformed();
      at++;
      const [item, whole] = value();
      if (item !== MISSING) out[name] = item;
      if (!whole) return [out, false];
      blank();
      if (at >= end) return [out, false];
      if (text[at] === ",") {
        at++;
        continue;
      }
      if (text[at] === "}") {
        at++;
        return [out, true];
      }
      throw new Malformed();
    }
  };

  try {
    const [read, whole] = value();
    if (read === MISSING) return null;
    return { value: read, complete: whole };
  } catch (error) {
    if (error instanceof Malformed) return null;
    throw error;
  }
}

/** A value held to a JSON schema (with `$defs`, as the app's are exported), the way decoding a
 * partly generated value treats it: an enum's value that isn't one of its cases goes, and so
 * does anything of the wrong type. Properties the schema doesn't name are kept. */
export function fitted(value: unknown, schema: unknown, root: unknown = schema): unknown {
  const node = resolve(schema, root);
  if (!isObject(node)) return value;
  if (Array.isArray(node.enum)) return node.enum.includes(value) ? value : MISSING_OUT;
  switch (node.type) {
    case "string":
      return typeof value === "string" ? value : MISSING_OUT;
    case "number":
    case "integer":
      return typeof value === "number" ? value : MISSING_OUT;
    case "boolean":
      return typeof value === "boolean" ? value : MISSING_OUT;
    case "array": {
      if (!Array.isArray(value)) return MISSING_OUT;
      return value.map((item) => fitted(item, node.items, root)).filter((item) => item !== MISSING_OUT);
    }
    case "object": {
      if (!isObject(value)) return MISSING_OUT;
      const properties = isObject(node.properties) ? node.properties : {};
      const out: JSONObject = {};
      for (const [name, item] of Object.entries(value)) {
        const kept = name in properties ? fitted(item, properties[name], root) : item;
        if (kept !== MISSING_OUT) out[name] = kept;
      }
      return out;
    }
    default:
      return value;
  }
}

/** What `fitted` gives for a value that doesn't fit, which the object or array holding it drops. */
const MISSING_OUT = Symbol("doesn't fit");

function resolve(schema: unknown, root: unknown): unknown {
  let node = schema;
  for (let depth = 0; depth < 20 && isObject(node) && typeof node.$ref === "string"; depth++) {
    const path = node.$ref.replace(/^#\//, "").split("/");
    node = path.reduce<unknown>((at, part) => (isObject(at) ? at[part] : undefined), root);
  }
  return node;
}

/** The partly written answer as an object, held to its schema; null until it's begun one. */
export function partialObject(text: string, schema: unknown): JSONObject | null {
  const read = readPartial(text);
  if (!read || !isObject(read.value)) return null;
  const held = fitted(read.value, schema);
  return isObject(held) ? held : null;
}
