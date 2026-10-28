// The working pages on the home page: their requests, their maths, and how they write numbers.
// The page is built with the defaults here (dollars and metres); in the browser, the same
// functions redo it in the visitor's own currency and units.

import type { Accent } from "./palette";

export type DemoID = "horizon" | "bill" | "groceries" | "pendulum";

export interface Demo {
  id: DemoID;
  accent: Accent;
  /** What's asked, as the composer types it. */
  request: (units: Units) => string;
}

export interface Units {
  locale: string;
  /** Miles and feet, not kilometres and metres. */
  imperial: boolean;
  currency: string;
  /** What the bill comes to, in that currency. */
  bill: number;
}

export const DEFAULT_UNITS: Units = { locale: "en-US", imperial: false, currency: "USD", bill: 240 };

export const DEMOS: Demo[] = [
  { id: "horizon", accent: "indigo", request: () => "How far away is the horizon?" },
  { id: "bill", accent: "orange", request: (units) => `Split a ${money(units.bill, units, 0)} bill four ways, with a tip` },
  { id: "groceries", accent: "green", request: () => "A grocery list for the week" },
  { id: "pendulum", accent: "purple", request: () => "Why does a pendulum swing?" },
];

/** A short name for each request, for the buttons that ask it again. */
export const SHORT: Record<DemoID, string> = {
  horizon: "The horizon",
  bill: "Split a bill",
  groceries: "Groceries",
  pendulum: "A pendulum",
};

// MARK: - Units

/** Where they are and how they write numbers, from the browser's language. */
export function unitsFor(language: string): Units {
  let region = "US";
  try {
    region = new Intl.Locale(language).maximize().region ?? "US";
  } catch {
    // An odd language tag: dollars and metres.
  }
  const currency = CURRENCY[region] ?? (EURO.includes(region) ? "EUR" : "USD");
  return { locale: language, imperial: ["US", "LR", "MM"].includes(region), currency, bill: 240 * (SCALE[currency] ?? 1) };
}

const CURRENCY: Record<string, string> = {
  US: "USD", GB: "GBP", IN: "INR", JP: "JPY", CA: "CAD", AU: "AUD", NZ: "NZD", CH: "CHF", SG: "SGD", AE: "AED",
  SE: "SEK", NO: "NOK", DK: "DKK", BR: "BRL", MX: "MXN", KR: "KRW", CN: "CNY", HK: "HKD", ZA: "ZAR", PL: "PLN",
};
const EURO = ["AT", "BE", "CY", "DE", "EE", "ES", "FI", "FR", "GR", "HR", "IE", "IT", "LT", "LU", "LV", "MT", "NL", "PT", "SI", "SK"];
/** So a dinner costs about what a dinner costs. */
const SCALE: Record<string, number> = { INR: 10, JPY: 100, KRW: 1000, MXN: 10, ZAR: 10, SEK: 10, NOK: 10, DKK: 10, CNY: 5, HKD: 5, BRL: 5, PLN: 4 };

export function money(amount: number, units: Units, digits?: number): string {
  const options: Intl.NumberFormatOptions = { style: "currency", currency: units.currency };
  if (digits !== undefined) {
    options.minimumFractionDigits = digits;
    options.maximumFractionDigits = digits;
  }
  return new Intl.NumberFormat(units.locale, options).format(amount);
}

function decimal(value: number, units: Units, digits: number): string {
  return new Intl.NumberFormat(units.locale, { maximumFractionDigits: digits, minimumFractionDigits: digits }).format(value);
}

/** A distance on the ground, in km or miles. */
export function distance(metres: number, units: Units): string {
  const value = units.imperial ? metres / 1609.344 : metres / 1000;
  return `${decimal(value, units, value < 10 ? 1 : 0)} ${units.imperial ? "mi" : "km"}`;
}

/** A height or a length, in metres or feet. */
export function length(metres: number, units: Units): string {
  if (units.imperial) return `${decimal(metres * 3.28084, units, metres < 3 ? 1 : 0)} ft`;
  return `${decimal(metres, units, metres < 10 ? 1 : 0)} m`;
}

export function seconds(value: number, units: Units): string {
  return `${decimal(value, units, value < 10 ? 1 : 0)} s`;
}

// MARK: - Sliders

/** A slider runs 0 to 1000; squared, so the everyday end gets most of its travel. */
export function fromSlider(position: number, low: number, high: number): number {
  return low + (high - low) * (position / 1000) ** 2;
}

export function toSlider(value: number, low: number, high: number): number {
  return Math.round(1000 * Math.sqrt((value - low) / (high - low)));
}

// MARK: - The horizon

export const EYES = { low: 1, high: 100, start: 1.7 };

/** From h metres up, the horizon is √(2Rh + h²) away. */
export function horizonDistance(height: number): number {
  const earth = 6_371_000;
  return Math.sqrt(2 * earth * height + height * height);
}

/** A slice of the Earth in a 600 × 140 box, someone standing on it (far taller than life), and
 * their line of sight grazing the curve. The higher they stand, the further along it touches
 * (HorizonFigure in WelcomeView.swift). */
export function horizonFigure(height: number) {
  const radius = 700;
  const center = { x: 300, y: 76 + radius };
  const lift = 10 + 80 * Math.sqrt(height / EYES.high);
  const stand = Math.asin((84 - 300) / radius);
  const reach = Math.acos(radius / (radius + lift));
  const point = (angle: number, at: number) => ({ x: center.x + at * Math.sin(angle), y: center.y - at * Math.cos(angle) });
  const ground = point(stand, radius);
  const eye = point(stand, radius + lift);
  const horizon = point(stand + reach, radius);
  const beyond = { x: horizon.x + (horizon.x - eye.x) * 0.3, y: horizon.y + (horizon.y - eye.y) * 0.3 };
  return { radius, center, ground, eye, horizon, beyond };
}

// MARK: - The bill

export const TIP = { low: 0, high: 25, start: 10 };
export const PEOPLE = { low: 2, high: 12, start: 4 };

// MARK: - The pendulum

export const ROPE = { low: 0.1, high: 5, start: 1 };

export const GRAVITY = { earth: 9.81, moon: 1.62, mars: 3.71 } as const;
export type World = keyof typeof GRAVITY;

/** One swing there and back, for a small swing: 2π√(L/g). */
export function period(rope: number, world: World): number {
  return 2 * Math.PI * Math.sqrt(rope / GRAVITY[world]);
}

// MARK: - Groceries

export const GROCERIES: { name: string; done: boolean }[] = [
  { name: "Milk", done: true },
  { name: "Eggs", done: false },
  { name: "Spinach", done: false },
  { name: "Rice", done: false },
  { name: "Bananas", done: false },
];
