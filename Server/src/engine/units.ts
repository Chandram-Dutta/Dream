// Units and money as the checker reads them (Dream/Engine/Units.swift, Formatting.swift's
// Currency, Live.swift's LiveUnits). The app reads the user's currency and measurement system
// from the phone's locale; here they come with the request, as `reader`, set for the length of
// each call into the engine (index.ts). The conversion factors are Foundation's own, truncated
// where Foundation's are, so a converted value is the number the app would show.

import type { EngineLocale } from "./types.ts";
import { characters, count, lower, prefix, trim, trimAll, upper } from "./swift.ts";

let current: EngineLocale = { currency: "USD", currencySymbol: "$", measurementSystem: "ussystem" };

/** Runs `body` for a reader, as Locale.current would be on their phone. */
export function asReader<T>(locale: EngineLocale | undefined, body: () => T): T {
  if (!locale) return body();
  const before = current;
  current = locale;
  try {
    return body();
  } finally {
    current = before;
  }
}

export type MeasurementSystem = "metric" | "us" | "uk";

/** The reader's measurement system, from the identifiers the app writes or the plain words. */
export function readerSystem(): MeasurementSystem {
  const written = lower(current.measurementSystem);
  return written === "ussystem" || written === "us" ? "us" : written === "uksystem" || written === "uk" ? "uk" : "metric";
}

export const Currency = {
  get code(): string {
    return current.currency || "USD";
  },

  /** How the reader writes their currency, like ₹ or US$. */
  get symbol(): string {
    if (current.currencySymbol) return current.currencySymbol;
    try {
      const locale = [current.language, current.region].filter(Boolean).join("-") || "en-US";
      const parts = new Intl.NumberFormat(locale, { style: "currency", currency: Currency.code }).formatToParts(0);
      return parts.find((part) => part.type === "currency")?.value ?? "$";
    } catch {
      return "$";
    }
  },

  /** Whether a unit is an ISO currency code, like USD. */
  isCode(unit: string): boolean {
    return unit.length === 3 && unit === upper(unit) && CURRENCY_CODES.has(unit);
  },
};

/** Locale.commonISOCurrencyCodes on iOS 27. */
const CURRENCY_CODES = new Set(
  ("AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BRL BSD BTN BWP BYN BZD CAD CDF CHF CLP CNY COP CRC CUC CUP CVE CZK " +
    "DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HRK HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR " +
    "KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN " +
    "PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SLL SOS SRD SSP STN SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH " +
    "UGX USD UYU UZS VEF VES VND VUV WST XAF XCD XCG XOF XPF YER ZAR ZMW ZWG").split(" "),
);

// MARK: - Dimensions

/** A Foundation unit: its class, and how a value becomes the class's base unit and back. The
 * class is the one Swift's `type(of:)` sees, which LiveUnits compares: Foundation's own units are
 * its private static subclasses, while ft/s, made in Units.swift, and the reciprocal mpg aren't. */
interface Dimension {
  kind: string;
  base(value: number): number;
  value(base: number): number;
}

function linear(kind: string, coefficient: number, constant = 0): Dimension {
  return { kind, base: (value) => value * coefficient + constant, value: (base) => (base - constant) / coefficient };
}

function reciprocal(kind: string, factor: number): Dimension {
  return { kind, base: (value) => factor / value, value: (base) => factor / base };
}

// Foundation's factors, read from UnitConverterLinear and UnitConverterReciprocal on iOS 27.
const DIMENSIONS = new Map<string, Dimension>([
  ["mm", linear("length", 0.001)], ["cm", linear("length", 0.01)], ["m", linear("length", 1)], ["km", linear("length", 1000)],
  ["in", linear("length", 0.0254)], ["ft", linear("length", 0.3048)], ["yd", linear("length", 0.9144)], ["mi", linear("length", 1609.344)],
  ["m/s", linear("speed", 1)], ["km/h", linear("speed", 0.277778)], ["mph", linear("speed", 0.44704)], ["ft/s", linear("speed (made)", 0.3048)],
  ["g", linear("mass", 0.001)], ["kg", linear("mass", 1)], ["t", linear("mass", 1000)], ["oz", linear("mass", 0.0283495)], ["lb", linear("mass", 0.453592)],
  ["ton", linear("mass", 907.185)],
  ["°C", linear("temperature", 1, 273.15)], ["°F", linear("temperature", 0.55555555555556, 255.37222222222428)],
  ["mL", linear("volume", 0.001)], ["L", linear("volume", 1)], ["m³", linear("volume", 1000)],
  ["fl oz", linear("volume", 0.0295735)], ["cup", linear("volume", 0.24)], ["pt", linear("volume", 0.473176)], ["qt", linear("volume", 0.946353)],
  ["gal", linear("volume", 3.78541)], ["ft³", linear("volume", 28.3168)],
  ["cm²", linear("area", 0.0001)], ["m²", linear("area", 1)], ["km²", linear("area", 1000000)], ["ha", linear("area", 10000)],
  ["in²", linear("area", 0.00064516)], ["ft²", linear("area", 0.09290304)], ["mi²", linear("area", 2589988.110336)], ["ac", linear("area", 4046.8564224)],
  ["L/100 km", linear("fuel", 1)], ["mpg", reciprocal("fuel (reciprocal)", 235.215)],
  ["kPa", linear("pressure", 1000)], ["bar", linear("pressure", 100000)], ["psi", linear("pressure", 6894.76)],
]);

const IMPERIAL = new Map<string, Dimension>([
  ["gal", linear("volume", 4.54609)], ["pt", linear("volume", 0.568261)], ["fl oz", linear("volume", 0.0284131)], ["mpg", reciprocal("fuel (reciprocal)", 282.481)],
]);

const METRIC = new Set(["mm", "cm", "m", "km", "m/s", "km/h", "g", "kg", "t", "°C", "mL", "L", "m³", "cm²", "m²", "km²", "ha", "L/100 km", "kPa", "bar"]);

const TO_CUSTOMARY = new Map(Object.entries({
  mm: "in", cm: "in", m: "ft", km: "mi", "m/s": "mph", "km/h": "mph", g: "oz", kg: "lb", t: "ton", "°C": "°F",
  mL: "fl oz", L: "gal", "m³": "ft³", "cm²": "in²", "m²": "ft²", "km²": "mi²", ha: "ac", "L/100 km": "mpg", kPa: "psi", bar: "psi",
}));

const TO_METRIC = new Map(Object.entries({
  in: "cm", ft: "m", yd: "m", mi: "km", mph: "km/h", "ft/s": "m/s", oz: "g", lb: "kg", ton: "t", "°F": "°C",
  "fl oz": "mL", cup: "mL", pt: "mL", qt: "L", gal: "L", "ft³": "m³", "in²": "cm²", "ft²": "m²", "mi²": "km²", ac: "ha",
  mpg: "L/100 km", psi: "kPa",
}));

const TO_UK_FROM_METRIC = new Map(Object.entries({ km: "mi", "km/h": "mph", "m/s": "mph", "L/100 km": "mpg (imp)" }));

const TO_UK_FROM_CUSTOMARY = new Map(Object.entries({
  oz: "g", lb: "kg", ton: "t", "°F": "°C", "fl oz": "mL", cup: "mL", pt: "mL", qt: "L", gal: "L", "ft³": "m³",
  "in²": "cm²", "ft²": "m²", mpg: "mpg (imp)",
}));

/** Words and other spellings models use, by the symbol Dream writes. Keys are lowercase. */
const WORDS = new Map(Object.entries({
  second: "s", seconds: "s", sec: "s", secs: "s", minute: "min", minutes: "min", mins: "min",
  hour: "h", hours: "h", hr: "h", hrs: "h",
  day: "days", days: "days", week: "weeks", weeks: "weeks", wk: "weeks", wks: "weeks",
  month: "months", months: "months", mo: "months", mos: "months", year: "years", years: "years", yr: "years", yrs: "years",
  metre: "m", metres: "m", meter: "m", meters: "m", kilometre: "km", kilometres: "km", kilometer: "km", kilometers: "km",
  centimetre: "cm", centimetres: "cm", centimeter: "cm", centimeters: "cm", millimetre: "mm", millimetres: "mm",
  millimeter: "mm", millimeters: "mm", km: "km", cm: "cm", mm: "mm",
  mile: "mi", miles: "mi", foot: "ft", feet: "ft", inch: "in", inches: "in", yard: "yd", yards: "yd",
  kmph: "km/h", kph: "km/h", "km/hr": "km/h", kmh: "km/h", "km/h": "km/h", mph: "mph", "mi/h": "mph", "m/s": "m/s",
  knot: "kn", knots: "kn", kt: "kn",
  gram: "g", grams: "g", kilogram: "kg", kilograms: "kg", kilo: "kg", kilos: "kg", kg: "kg", kgs: "kg",
  tonne: "t", tonnes: "t", pound: "lb", pounds: "lb", lbs: "lb", ounce: "oz", ounces: "oz",
  l: "L", litre: "L", litres: "L", liter: "L", liters: "L", ml: "mL", millilitre: "mL", millilitres: "mL",
  milliliter: "mL", milliliters: "mL", gallon: "gal", gallons: "gal", cups: "cup", "fl. oz": "fl oz", "fl.oz": "fl oz",
  "°c": "°C", "deg c": "°C", degc: "°C", celsius: "°C", "degrees celsius": "°C", "°f": "°F", "deg f": "°F", degf: "°F",
  fahrenheit: "°F", "degrees fahrenheit": "°F", kelvin: "K", deg: "°", degree: "°", degrees: "°", rad: "rad", radians: "rad",
  "sq m": "m²", "sq. m": "m²", "square metres": "m²", "square meters": "m²", "sq km": "km²", "sq ft": "ft²", "sq. ft": "ft²",
  "square feet": "ft²", "sq mi": "mi²", acre: "ac", acres: "ac", hectare: "ha", hectares: "ha",
  "l/100km": "L/100 km", "l/100 km": "L/100 km", "km/l": "km/L", kpa: "kPa", kwh: "kWh", kw: "kW", kj: "kJ",
  hz: "Hz", khz: "kHz", mhz: "MHz",
}));

/** Spans of time a calendar counts. */
const CALENDAR = new Set(["days", "weeks", "months", "years"]);

/** Common symbols with no counterpart elsewhere, recognised so they can leave a label. */
const SYMBOLS = new Set([
  "s", "ms", "µs", "ns", "min", "h", "K", "J", "kJ", "MJ", "cal", "kcal", "Wh", "kWh", "MWh", "W", "kW", "MW", "GW",
  "Hz", "kHz", "MHz", "GHz", "N", "kN", "Pa", "hPa", "MPa", "atm", "mmHg", "V", "mV", "kV", "A", "mA", "Ω", "kΩ",
  "mol", "rad", "°", "m/s²", "km/s", "dB", "lx", "lm", "B", "kB", "MB", "GB", "TB", "bpm", "rpm", "AU", "ly", "eV",
  "nm", "µm", "mg", "µg", "kn", "km/L", "Mbps", "kg/m³", "g/cm³", "N·m", "m³/s",
]);

const LATEX_UNIT = /\\(?:mathrm|text|textrm|rm|mbox)\{([^{}]*)\}/gu;

const TIDY_REPLACEMENTS: [string, string][] = [
  ["$", ""], ["\\,", " "], ["^{\\circ}", "°"], ["^\\circ", "°"], ["\\circ", "°"], ["\\mu", "µ"], ["\\cdot", "·"],
  ["^{2}", "²"], ["^2", "²"], ["^{3}", "³"], ["^3", "³"], ["^{-1}", "⁻¹"], ["^-1", "⁻¹"], ["℃", "°C"], ["℉", "°F"],
];

export const Units = {
  /** A unit as Dream writes it: "m/s^2" is m/s², "seconds" is s and "deg" is °. */
  tidy(raw: string): string {
    let unit = trimAll(raw);
    unit = unit.replace(LATEX_UNIT, (_, inner: string) => inner);
    for (const [written, symbol] of TIDY_REPLACEMENTS) unit = unit.replaceAll(written, symbol);
    unit = trim(unit);
    return WORDS.get(lower(unit)) ?? unit;
  },

  /** Whether text reads as a unit: one with a counterpart elsewhere, a span of time, or a common symbol. */
  isUnit(text: string): boolean {
    const unit = Units.tidy(text);
    return DIMENSIONS.has(unit) || CALENDAR.has(unit) || SYMBOLS.has(unit);
  },

  dimension(unit: string, system: MeasurementSystem): Dimension | undefined {
    if (system === "uk") {
      const imperial = IMPERIAL.get(unit);
      if (imperial) return imperial;
    }
    return DIMENSIONS.get(unit);
  },

  /** The reader's counterpart of a unit, for an everyday quantity: its symbol and dimension. */
  counterpart(unit: string, written: MeasurementSystem, reader: MeasurementSystem): [string, Dimension] | null {
    void written;
    let target: string | undefined;
    switch (reader) {
      case "us": target = TO_CUSTOMARY.get(unit); break;
      case "uk": target = METRIC.has(unit) ? TO_UK_FROM_METRIC.get(unit) : TO_UK_FROM_CUSTOMARY.get(unit); break;
      default: target = TO_METRIC.get(unit);
    }
    if (target === undefined) return null;
    if (target === "mpg (imp)") return ["mpg", IMPERIAL.get("mpg")!];
    const dimension = Units.dimension(target, reader);
    return dimension ? [target, dimension] : null;
  },

  /** Text after a live value with its unit taken off the front: " m away" → " away". Null when it doesn't start with it. */
  dropping(unit: string, text: string): string | null {
    // "in" is also a word, so "{height} in total" keeps it.
    if (unit === "in") return null;
    const all = characters(text);
    let start = 0;
    while (start < all.length && (all[start] === " " || all[start] === " " || all[start] === " ")) start++;
    const rest = all.slice(start).join("");
    const tokens = splitSpaces(rest, 2);
    for (const n of [2, 1]) {
      if (tokens.length < n) continue;
      const candidate = tokens.slice(0, n).join(" ");
      const word = trimPunctuation(candidate);
      if (word === "" || Units.tidy(word) !== unit) continue;
      return characters(rest).slice(count(word)).join("");
    }
    return null;
  },
};

/** `split(separator: " ", maxSplits:, omittingEmptySubsequences: false)`. */
function splitSpaces(text: string, maxSplits: number): string[] {
  const pieces: string[] = [];
  let rest = text;
  while (pieces.length < maxSplits) {
    const at = rest.indexOf(" ");
    if (at < 0) break;
    pieces.push(rest.slice(0, at));
    rest = rest.slice(at + 1);
  }
  pieces.push(rest);
  return pieces;
}

function trimPunctuation(text: string): string {
  const marks = new Set([".", ",", ";", ":", "!", "?", ")"]);
  const all = Array.from(text);
  let start = 0;
  let end = all.length;
  while (start < end && marks.has(all[start])) start++;
  while (end > start && marks.has(all[end - 1])) end--;
  return all.slice(start, end).join("");
}

/** Converting a provider's metric values into the units an input is written in. */
export const LiveUnits = {
  convert(value: number, fromRaw: string, toRaw: string): number | null {
    const [from, to] = [Units.tidy(fromRaw), Units.tidy(toRaw)];
    if (from === to) return value;
    const seconds = new Map([["s", 1], ["min", 60], ["h", 3600], ["days", 86_400]]);
    const a0 = seconds.get(from);
    const b0 = seconds.get(to);
    if (a0 !== undefined && b0 !== undefined) return (value * a0) / b0;
    const a = Units.dimension(from, "metric");
    const b = Units.dimension(to, "metric") ?? Units.dimension(to, "us");
    if (!a || !b || a.kind !== b.kind) return null;
    return b.value(a.base(value));
  },

  /** A metric unit as this reader would see it, like °F for °C in the US, with the value in it. */
  local(value: number, unit: string): { value: number; unit: string } {
    const system = readerSystem();
    if (system === "metric") return { value, unit };
    const counterpart = Units.counterpart(unit, "metric", system);
    if (!counterpart) return { value, unit };
    const converted = LiveUnits.convert(value, unit, counterpart[0]);
    return converted === null ? { value, unit } : { value: converted, unit: counterpart[0] };
  },
};

/** Whether a format has units: plain numbers and counts. */
export function isMeasured(format: string): boolean {
  return format === "number" || format === "integer";
}

/** The first `n` characters of a string, for labels and sites. */
export { prefix };
