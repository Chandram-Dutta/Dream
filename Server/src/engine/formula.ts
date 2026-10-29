// A parsed formula (Dream/Engine/Formula.swift, Formula+Records.swift): arithmetic, comparisons,
// conditionals and the usual maths functions, small enough for a small model to write correctly.
// The parser, the evaluator and the way a formula is written back out are the app's, error
// messages included, since the checker sends those to the model.

import { characters, double, isDigit, isLetter, isNumber, isWhitespace, lgamma, lower, max, maxOf, min, minOf, plain, pow, round, tgamma } from "./swift.ts";

export type Expr =
  | { kind: "number"; value: number }
  | { kind: "name"; name: string }
  | { kind: "unary"; op: string; operand: Expr }
  | { kind: "binary"; op: string; lhs: Expr; rhs: Expr }
  | { kind: "conditional"; condition: Expr; then: Expr; otherwise: Expr }
  | { kind: "call"; function: string; arguments: Expr[] };

export class FormulaError extends Error {
  readonly description: string;
  constructor(description: string) {
    super(description);
    this.description = description;
  }
}

/** What an error says, as Swift's `"\(error)"` writes a FormulaError. */
export function describeError(error: unknown): string {
  return error instanceof FormulaError ? error.description : String(error);
}

export const FUNCTIONS = new Set([
  "min", "max", "round", "floor", "ceil", "abs", "sqrt", "cbrt", "pow", "exp", "log", "ln", "log10", "log2",
  "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "hypot",
  "sign", "mod", "fact", "choose", "if", "clamp", "sum", "avg", "count", "first", "last",
]);

/** Names every formula can use. An input or output with the same name wins. */
export const CONSTANTS = new Map<string, number>([["pi", Math.PI], ["e", Math.E], ["tau", 2 * Math.PI]]);

export const AGGREGATES = new Set(["sum", "count", "avg", "min", "max", "first", "last"]);

export const number = (value: number): Expr => ({ kind: "number", value });
export const name = (name: string): Expr => ({ kind: "name", name });
export const call = (fn: string, args: Expr[]): Expr => ({ kind: "call", function: fn, arguments: args });

// MARK: - Tokens

type Token = { kind: "number"; value: number } | { kind: "name"; name: string } | { kind: "symbol"; symbol: string };

function tokenText(token: Token): string {
  switch (token.kind) {
    case "number": return plain(token.value);
    case "name": return `'${token.name}'`;
    case "symbol": return `'${token.symbol}'`;
  }
}

const isSymbol = (token: Token | undefined, symbol: string) => token?.kind === "symbol" && token.symbol === symbol;

function tokenize(source: string): Token[] {
  const all = characters(source);
  const tokens: Token[] = [];
  let index = 0;
  const at = (position: number): string | undefined => all[position];
  while (index < all.length) {
    const character = all[index];
    if (isWhitespace(character) || character === "$") {
      index += 1;
      continue;
    }
    if (isDigit(character) || (character === "." && isDigit(at(index + 1)))) {
      let end = index;
      for (let next = at(end); next !== undefined && (isDigit(next) || next === "." || next === "_"); next = at(end)) end += 1;
      const e = at(end);
      if ((e === "e" || e === "E") && (isDigit(at(end + 1)) || ((at(end + 1) === "-" || at(end + 1) === "+") && isDigit(at(end + 2))))) {
        end += 2;
        while (isDigit(at(end))) end += 1;
      }
      const text = all.slice(index, end).join("").replaceAll("_", "");
      const value = double(text);
      if (value === null) throw new FormulaError(`can't read the number ${text}`);
      tokens.push({ kind: "number", value });
      index = end;
      continue;
    }
    if (isLetter(character) || character === "_") {
      let end = index;
      for (let next = at(end); next !== undefined && (isLetter(next) || isNumber(next) || next === "_" || next === "."); next = at(end)) end += 1;
      let word = all.slice(index, end).join("");
      if (lower(word).startsWith("math.")) word = all.slice(index + 5, end).join("");
      switch (lower(word)) {
        case "and": tokens.push({ kind: "symbol", symbol: "&&" }); break;
        case "or": tokens.push({ kind: "symbol", symbol: "||" }); break;
        case "not": tokens.push({ kind: "symbol", symbol: "!" }); break;
        case "true": tokens.push({ kind: "number", value: 1 }); break;
        case "false": tokens.push({ kind: "number", value: 0 }); break;
        case "pi": tokens.push({ kind: "name", name: "pi" }); break;
        default: tokens.push({ kind: "name", name: word });
      }
      index = end;
      continue;
    }
    const next = at(index + 1);
    if (next !== undefined) {
      const pair = character + next;
      if (["<=", ">=", "==", "!=", "&&", "||", "**"].includes(pair)) {
        tokens.push({ kind: "symbol", symbol: pair === "**" ? "^" : pair });
        index += 2;
        continue;
      }
    }
    switch (character) {
      case "+": case "-": case "*": case "/": case "%": case "^": case "(": case ")": case ",": case "?": case ":": case "<": case ">": case "!":
        tokens.push({ kind: "symbol", symbol: character });
        break;
      case "=": tokens.push({ kind: "symbol", symbol: "==" }); break;
      case "×": case "·": tokens.push({ kind: "symbol", symbol: "*" }); break;
      case "÷": tokens.push({ kind: "symbol", symbol: "/" }); break;
      case "−": case "–": tokens.push({ kind: "symbol", symbol: "-" }); break;
      case "≤": tokens.push({ kind: "symbol", symbol: "<=" }); break;
      case "≥": tokens.push({ kind: "symbol", symbol: ">=" }); break;
      case "≠": tokens.push({ kind: "symbol", symbol: "!=" }); break;
      default: throw new FormulaError(`unexpected character '${character}'`);
    }
    index += 1;
  }
  return tokens;
}

// MARK: - Parsing

/** Binding powers: left < right means left-associative. */
const INFIX = new Map<string, [number, number]>([
  ["||", [3, 4]], ["&&", [5, 6]],
  ["==", [7, 8]], ["!=", [7, 8]],
  ["<", [9, 10]], ["<=", [9, 10]], [">", [9, 10]], [">=", [9, 10]],
  ["+", [11, 12]], ["-", [11, 12]],
  ["*", [13, 14]], ["/", [13, 14]], ["%", [13, 14]],
  ["^", [18, 17]],
]);
const PREFIX_POWER = 15;
const CONDITIONAL_POWER = 1;

/** A Pratt parser, as Formula.swift's. */
class Parser {
  readonly tokens: Token[];
  position = 0;

  constructor(tokens: Token[]) {
    this.tokens = tokens;
  }

  get peek(): Token | undefined {
    return this.tokens[this.position];
  }

  advance(): Token | undefined {
    const token = this.peek;
    this.position += 1;
    return token;
  }

  expect(symbol: string) {
    if (!isSymbol(this.advance(), symbol)) throw new FormulaError(`expected '${symbol}'`);
  }

  parse(minimumPower: number): Expr {
    let lhs = this.parsePrefix();
    for (let token = this.peek; token?.kind === "symbol"; token = this.peek) {
      const op = token.symbol;
      if (op === "?") {
        if (!(CONDITIONAL_POWER >= minimumPower)) break;
        this.position += 1;
        const then = this.parse(0);
        this.expect(":");
        lhs = { kind: "conditional", condition: lhs, then, otherwise: this.parse(CONDITIONAL_POWER) };
        continue;
      }
      const power = INFIX.get(op);
      if (!power || !(power[0] >= minimumPower)) break;
      this.position += 1;
      lhs = { kind: "binary", op, lhs, rhs: this.parse(power[1]) };
    }
    return lhs;
  }

  parsePrefix(): Expr {
    const token = this.advance();
    if (!token) throw new FormulaError("the formula ends too early");
    if (token.kind === "number") return number(token.value);
    if (token.kind === "name") {
      if (!isSymbol(this.peek, "(")) return name(token.name);
      this.position += 1;
      const args: Expr[] = [];
      if (isSymbol(this.peek, ")")) {
        this.position += 1;
        return call(lower(token.name), args);
      }
      while (true) {
        args.push(this.parse(0));
        const next = this.advance();
        if (!next) throw new FormulaError("missing ')'");
        if (isSymbol(next, ")")) return call(lower(token.name), args);
        if (!isSymbol(next, ",")) throw new FormulaError(`expected ',' or ')' but found ${tokenText(next)}`);
      }
    }
    if (token.symbol === "(") {
      const inner = this.parse(0);
      this.expect(")");
      return inner;
    }
    if (token.symbol === "-" || token.symbol === "+" || token.symbol === "!") {
      const operand = this.parse(PREFIX_POWER);
      return token.symbol === "+" ? operand : { kind: "unary", op: token.symbol, operand };
    }
    throw new FormulaError(`unexpected ${tokenText(token)}`);
  }
}

/** `Expr.parse`: throws a FormulaError saying what's wrong. */
export function parse(source: string): Expr {
  const parser = new Parser(tokenize(source));
  if (parser.tokens.length === 0) throw new FormulaError("the formula is empty");
  // Parsing and evaluating recurse as deep as a formula nests; a shared surface could hold one
  // built to exhaust the stack.
  if (parser.tokens.length > 300) throw new FormulaError("the formula is too long");
  const expr = parser.parse(0);
  const extra = parser.peek;
  if (extra) throw new FormulaError(`unexpected ${tokenText(extra)}`);
  return expr;
}

/** A formula or its error, kept, as FormulaCache does: the checker parses the same ones often. */
const cache = new Map<string, Expr | FormulaError>();

export function parseCached(source: string): Expr {
  let hit = cache.get(source);
  if (hit === undefined) {
    if (cache.size > 4000) cache.clear();
    try {
      hit = parse(source);
    } catch (error) {
      hit = error instanceof FormulaError ? error : new FormulaError(String(error));
    }
    cache.set(source, hit);
  }
  if (hit instanceof FormulaError) throw hit;
  return hit;
}

/** The parsed formula, or null where Swift writes `try? Expr.parse`. */
export function tryParse(source: string): Expr | null {
  try {
    return parseCached(source);
  } catch {
    return null;
  }
}

// MARK: - Reading a formula

/** Input and output names the formula refers to. */
export function names(expr: Expr, into = new Set<string>()): Set<string> {
  switch (expr.kind) {
    case "number": break;
    case "name": into.add(expr.name); break;
    case "unary": names(expr.operand, into); break;
    case "binary": names(expr.lhs, into); names(expr.rhs, into); break;
    case "conditional": names(expr.condition, into); names(expr.then, into); names(expr.otherwise, into); break;
    case "call": for (const argument of expr.arguments) names(argument, into); break;
  }
  return into;
}

export function functionNames(expr: Expr, into = new Set<string>()): Set<string> {
  switch (expr.kind) {
    case "number": case "name": break;
    case "unary": functionNames(expr.operand, into); break;
    case "binary": functionNames(expr.lhs, into); functionNames(expr.rhs, into); break;
    case "conditional": functionNames(expr.condition, into); functionNames(expr.then, into); functionNames(expr.otherwise, into); break;
    case "call":
      into.add(expr.function);
      for (const argument of expr.arguments) functionNames(argument, into);
      break;
  }
  return into;
}

/** Whether every function it calls is one formulas can use. */
export function usesKnownFunctions(expr: Expr): boolean {
  for (const fn of functionNames(expr)) if (!FUNCTIONS.has(fn)) return false;
  return true;
}

export function renamed(expr: Expr, renames: Map<string, string>): Expr {
  switch (expr.kind) {
    case "number": return expr;
    case "name": return name(renames.get(expr.name) ?? expr.name);
    case "unary": return { kind: "unary", op: expr.op, operand: renamed(expr.operand, renames) };
    case "binary": return { kind: "binary", op: expr.op, lhs: renamed(expr.lhs, renames), rhs: renamed(expr.rhs, renames) };
    case "conditional":
      return { kind: "conditional", condition: renamed(expr.condition, renames), then: renamed(expr.then, renames), otherwise: renamed(expr.otherwise, renames) };
    case "call": return call(expr.function, expr.arguments.map((argument) => renamed(argument, renames)));
  }
}

/** Every list reference, like `expenses.amount` in `sum(expenses.amount)`, with the function that totals it. */
export function totals(expr: Expr): { function: string; name: string }[] {
  switch (expr.kind) {
    case "number": case "name": return [];
    case "unary": return totals(expr.operand);
    case "binary": return [...totals(expr.lhs), ...totals(expr.rhs)];
    case "conditional": return [...totals(expr.condition), ...totals(expr.then), ...totals(expr.otherwise)];
    case "call": {
      const only = expr.arguments[0];
      if (expr.arguments.length === 1 && only.kind === "name") return [{ function: expr.function, name: only.name }];
      return expr.arguments.flatMap(totals);
    }
  }
}

// MARK: - Writing a formula out

/** `Expr.description`: the formula with only the brackets it needs. */
export function describe(expr: Expr): string {
  return render(expr, 0);
}

function render(expr: Expr, parent: number): string {
  switch (expr.kind) {
    case "number": return plain(expr.value);
    case "name": return expr.name;
    case "unary": {
      const text = expr.op + render(expr.operand, PREFIX_POWER);
      return PREFIX_POWER < parent ? `(${text})` : text;
    }
    case "binary": {
      const [left, right] = INFIX.get(expr.op) ?? [0, 0];
      const leftAssociative = right > left;
      const text = `${render(expr.lhs, leftAssociative ? left : left + 1)} ${expr.op} ${render(expr.rhs, leftAssociative ? right : left)}`;
      return left < parent ? `(${text})` : text;
    }
    case "conditional": {
      const text = `${render(expr.condition, CONDITIONAL_POWER + 1)} ? ${render(expr.then, 0)} : ${render(expr.otherwise, CONDITIONAL_POWER)}`;
      return CONDITIONAL_POWER < parent ? `(${text})` : text;
    }
    case "call": return `${expr.function}(${expr.arguments.map((argument) => render(argument, 0)).join(", ")})`;
  }
}

// MARK: - Working it out

export type Lookup = (name: string) => number;
export type Column = (name: string) => number[] | null;

/** What each function makes of a whole list. Empty lists total and count 0; the rest aren't numbers. */
export function aggregate(fn: string, values: number[]): number {
  switch (fn) {
    case "sum": return values.reduce((a, b) => a + b, 0);
    case "count": return values.filter((value) => value !== 0).length;
    case "avg": return values.length === 0 ? NaN : values.reduce((a, b) => a + b, 0) / values.length;
    case "min": return minOf(values) ?? NaN;
    case "max": return maxOf(values) ?? NaN;
    case "first": return values.length ? values[0] : NaN;
    case "last": return values.length ? values[values.length - 1] : NaN;
    default: throw new FormulaError(`${fn}() can't total a list; use sum, avg, min, max, count, first or last`);
  }
}

/** Booleans are numbers: comparisons give 1 or 0, and anything non-zero is true. */
export function evaluate(expr: Expr, lookup: Lookup, column: Column = () => null): number {
  switch (expr.kind) {
    case "number": return expr.value;
    case "name": return lookup(expr.name);
    case "unary": {
      const value = evaluate(expr.operand, lookup, column);
      return expr.op === "!" ? (value === 0 ? 1 : 0) : -value;
    }
    case "binary": {
      const a = evaluate(expr.lhs, lookup, column);
      const b = evaluate(expr.rhs, lookup, column);
      switch (expr.op) {
        case "+": return a + b;
        case "-": return a - b;
        case "*": return a * b;
        case "/": return a / b;
        case "%": return a % b;
        case "^": return pow(a, b);
        case "<": return a < b ? 1 : 0;
        case "<=": return a <= b ? 1 : 0;
        case ">": return a > b ? 1 : 0;
        case ">=": return a >= b ? 1 : 0;
        case "==": return a === b ? 1 : 0;
        case "!=": return a !== b ? 1 : 0;
        case "&&": return a !== 0 && b !== 0 ? 1 : 0;
        case "||": return a !== 0 || b !== 0 ? 1 : 0;
        default: throw new FormulaError(`unknown operator ${expr.op}`);
      }
    }
    case "conditional":
      return evaluate(expr.condition, lookup, column) !== 0 ? evaluate(expr.then, lookup, column) : evaluate(expr.otherwise, lookup, column);
    case "call": return evaluateCall(expr.function, expr.arguments, lookup, column);
  }
}

function evaluateCall(fn: string, args: Expr[], lookup: Lookup, column: Column): number {
  if (fn === "if") {
    if (args.length !== 3) throw new FormulaError("if() needs a condition and two values");
    return evaluate(args[0], lookup, column) !== 0 ? evaluate(args[1], lookup, column) : evaluate(args[2], lookup, column);
  }
  const only = args[0];
  if (args.length === 1 && only.kind === "name") {
    const values = column(only.name);
    if (values !== null) return aggregate(fn, values);
  }
  const values = args.map((argument) => evaluate(argument, lookup, column));
  const needs = (n: number) => {
    if (values.length !== n) throw new FormulaError(`${fn}() needs ${n} value${n === 1 ? "" : "s"}`);
  };
  switch (fn) {
    case "min": {
      const result = minOf(values);
      if (result === undefined) throw new FormulaError("min() needs values");
      return result;
    }
    case "max": {
      const result = maxOf(values);
      if (result === undefined) throw new FormulaError("max() needs values");
      return result;
    }
    case "sum": return values.reduce((a, b) => a + b, 0);
    case "count": return values.filter((value) => value !== 0).length;
    case "first":
      if (!values.length) throw new FormulaError("first() needs values");
      return values[0];
    case "last":
      if (!values.length) throw new FormulaError("last() needs values");
      return values[values.length - 1];
    case "avg":
      if (!values.length) throw new FormulaError("avg() needs values");
      return values.reduce((a, b) => a + b, 0) / values.length;
    case "round":
      if (values.length === 2) {
        const scale = pow(10, round(values[1]));
        return round(values[0] * scale) / scale;
      }
      needs(1);
      return round(values[0]);
    case "floor": needs(1); return Math.floor(values[0]);
    case "ceil": needs(1); return Math.ceil(values[0]);
    case "abs": needs(1); return Math.abs(values[0]);
    case "sqrt": needs(1); return Math.sqrt(values[0]);
    case "pow": needs(2); return pow(values[0], values[1]);
    case "log":
      if (values.length === 2) return Math.log(values[0]) / Math.log(values[1]);
      needs(1);
      return Math.log(values[0]);
    case "ln": needs(1); return Math.log(values[0]);
    case "log10": needs(1); return Math.log10(values[0]);
    case "log2": needs(1); return Math.log2(values[0]);
    case "exp": needs(1); return Math.exp(values[0]);
    case "cbrt": needs(1); return Math.cbrt(values[0]);
    case "sin": needs(1); return Math.sin(values[0]);
    case "cos": needs(1); return Math.cos(values[0]);
    case "tan": needs(1); return Math.tan(values[0]);
    case "asin": needs(1); return Math.asin(values[0]);
    case "acos": needs(1); return Math.acos(values[0]);
    case "atan": needs(1); return Math.atan(values[0]);
    case "atan2": needs(2); return Math.atan2(values[0], values[1]);
    case "sinh": needs(1); return Math.sinh(values[0]);
    case "cosh": needs(1); return Math.cosh(values[0]);
    case "tanh": needs(1); return Math.tanh(values[0]);
    case "hypot": needs(2); return Math.hypot(values[0], values[1]);
    case "sign": needs(1); return values[0] > 0 ? 1 : values[0] < 0 ? -1 : 0;
    case "mod": needs(2); return values[0] - values[1] * Math.floor(values[0] / values[1]);
    case "fact":
      needs(1);
      if (!(values[0] >= 0)) return NaN;
      return tgamma(values[0] + 1);
    case "choose": {
      needs(2);
      const [n, k] = values;
      if (!(k >= 0 && n >= k)) return 0;
      return round(Math.exp(lgamma(n + 1) - lgamma(k + 1) - lgamma(n - k + 1)));
    }
    case "clamp": needs(3); return min(max(values[0], values[1]), values[2]);
    default: throw new FormulaError(`unknown function ${fn}()`);
  }
}
