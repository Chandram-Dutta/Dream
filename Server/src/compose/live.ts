// Live data while a page is written on the server, ported from the app's live tool
// (Dream/Generation/LiveTool.swift, LiveSources.swift) and its providers, so a page made here
// declares the same sources a page made on the phone does. The phone reads every source again
// itself (WeatherKit, MapKit, ExchangeRate-API), so what's kept on the page is exactly what the
// app's providers write: the same field names, metric units, formats and meanings
// (Dream/Engine/Live.swift's Source and SourceField).
//
//   weather       Open-Meteo, forecast and geocoding, no key: the fields WeatherProvider reads
//                 from WeatherKit (LiveWeather.swift). "current location" is where the request
//                 came from, as Cloudflare places it; a place's day is the place's own.
//   exchangeRate  open.er-api.com, as LiveRates.swift reads it, each base kept until the service
//                 says its next update is due.
//   route         a travel time, which only the phone can read (Apple Maps): sent to it as its
//                 own live tool when it offers one, and otherwise said to be unreadable.
//
// What a provider returns is data from outside, never instructions: only its numbers and a short
// summary reach the model. The words the tool answers with are the app's, from generation.json
// (toolText.live); the providers' own messages are written here, as in their Swift files.
//
// test/compose.mjs runs it in Node, with a stand-in for `fetch`.

import { minutes } from "../engine/checker-live";
import type { Source, SourceField } from "../engine/index";
import { identifier } from "../engine/names";
import { plain, round } from "../engine/swift";
import { asReader, LiveUnits } from "../engine/units";
import { fill, type Generation } from "./prompts";

type JSONObject = Record<string, unknown>;
type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

/** Wikimedia and the others ask tools for a name and a way to reach whoever runs them. */
export const USER_AGENT = "Dream/0.1 (Dream's server; +https://dream.onlychan.xyz/support)";

/** Why a source couldn't be read, in words the model can act on (LiveError). */
export class LiveError extends Error {
  readonly reason: "denied" | "notFound" | "unavailable";

  constructor(reason: "denied" | "notFound" | "unavailable", message: string) {
    super(message);
    this.name = "LiveError";
    this.reason = reason;
  }
}

/** What a source read (SourceReading): its fields, and a summary for the model. */
export interface Reading {
  fields: SourceField[];
  summary: string;
}

/** Where the request came from, as Cloudflare places it: the weather "here" (Places.here). */
export interface Here {
  latitude: number;
  longitude: number;
  /** What to call it, like Bengaluru. */
  city?: string;
  /** Where days start and end there, like Asia/Kolkata. */
  timeZone?: string;
}

/** The request's locale, as ComposeRequest has it: whose words and units the values are in. */
export interface Reader {
  language: string;
  region: string;
  currency: string;
  measurementSystem: string;
}

// MARK: - Days and times

const DAY = 86_400_000;
const WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

/** A time zone that exists, or UTC. */
function zone(name: string | undefined): string {
  if (!name) return "UTC";
  try {
    new Intl.DateTimeFormat("en", { timeZone: name });
    return name;
  } catch {
    return "UTC";
  }
}

/** The day it is in a time zone, as midnight UTC of that date. */
export function today(now: number, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: zone(timeZone), year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(now);
  const part = (type: string) => Number(parts.find((item) => item.type === type)?.value);
  return Date.UTC(part("year"), part("month") - 1, part("day"));
}

const isoDay = (day: number) => new Date(day).toISOString().slice(0, 10);

/** LiveDay.date: the day named, counted from `start` (a day as `today` gives it): today,
 * tonight, tomorrow, a weekday (the coming one, or today if it's that day), the weekend (the
 * coming Saturday), "in 3 days" or YYYY-MM-DD. Null if it isn't one. */
export function liveDay(text: string, start: number): number | null {
  let words = text.toLowerCase().trim();
  for (const prefix of ["this ", "next ", "coming ", "on "]) if (words.startsWith(prefix)) words = words.slice(prefix.length);
  const days = (count: number) => start + count * DAY;
  switch (words) {
    case "":
    case "today":
    case "tonight":
    case "now":
    case "this evening":
    case "this morning":
    case "this afternoon":
      return start;
    case "tomorrow":
      return days(1);
    case "day after tomorrow":
    case "the day after tomorrow":
      return days(2);
    case "weekend":
      words = "saturday";
      break;
    default:
      break;
  }
  const inDays = /^in (\d{1,2}) days?$/u.exec(words);
  if (inDays) return days(Number(inDays[1]));
  const letters = [...words];
  const index = WEEKDAYS.findIndex((day) => day === words || (day.slice(0, 3) === letters.slice(0, 3).join("") && letters.length >= 3 && day.startsWith(words)));
  if (index >= 0) return days((index - new Date(start).getUTCDay() + 7) % 7);
  const date = /^(\d{4})-(\d{1,2})-(\d{1,2})$/u.exec(words);
  if (date) return Date.UTC(Number(date[1]), Number(date[2]) - 1, Number(date[3]));
  return null;
}

/** The reader's way of writing dates and times, like en-IN. */
function localeOf(reader: Reader): string {
  const tag = [reader.language, reader.region].filter(Boolean).join("-");
  try {
    return Intl.getCanonicalLocales(tag)[0] ?? "en";
  } catch {
    return "en";
  }
}

// MARK: - Places

/** A place, found (LivePlace). */
interface Place {
  name: string;
  latitude: number;
  longitude: number;
  timeZone: string;
}

/** Places found by name, kept a while, since several sources on one screen often share one. */
const placesFound = new Map<string, Place>();

/** Places.find: where the user is for "current location" and the like, or a place by name, from
 * Open-Meteo's geocoding. A name with a region after a comma ("Cubbon Park, Bengaluru") that
 * isn't found whole is looked for by its first part, preferring one in the region named. */
async function findPlace(text: string, here: Here | null, fetcher: Fetch, language: string): Promise<Place> {
  const name = text.trim();
  if (isHere(name)) {
    if (!here) throw new LiveError("unavailable", "Dream couldn't find where you are.");
    return { name: here.city || "your location", latitude: here.latitude, longitude: here.longitude, timeZone: zone(here.timeZone) };
  }
  const key = name.toLowerCase();
  const known = placesFound.get(key);
  if (known) return known;
  const search = async (query: string): Promise<JSONObject[]> => {
    const url = new URL("https://geocoding-api.open-meteo.com/v1/search");
    url.searchParams.set("name", query);
    url.searchParams.set("count", "5");
    url.searchParams.set("language", /^[a-z]{2}/i.exec(language)?.[0]?.toLowerCase() ?? "en");
    url.searchParams.set("format", "json");
    const answer = await getJSON(url.href, fetcher);
    if (!answer) throw new LiveError("unavailable", "The weather isn't available right now.");
    return Array.isArray(answer.results) ? answer.results.filter(isObject) : [];
  };
  let results = await search(name);
  const parts = name.split(",").map((part) => part.trim()).filter(Boolean);
  if (!results.length && parts.length > 1) {
    const within = parts.slice(1).map((part) => part.toLowerCase());
    results = (await search(parts[0])).sort((a, b) => Number(regionMatches(b, within)) - Number(regionMatches(a, within)));
  }
  const found = results.find((result) => Number.isFinite(result.latitude) && Number.isFinite(result.longitude));
  if (!found) throw new LiveError("notFound", `Maps couldn't find ${name}.`);
  const place = { name: typeof found.name === "string" && found.name ? found.name : name, latitude: found.latitude as number, longitude: found.longitude as number, timeZone: zone(typeof found.timezone === "string" ? found.timezone : undefined) };
  if (placesFound.size > 500) placesFound.delete(placesFound.keys().next().value!);
  placesFound.set(key, place);
  return place;
}

function regionMatches(result: JSONObject, within: string[]): boolean {
  const names = [result.country, result.admin1, result.admin2, result.country_code].filter((value): value is string => typeof value === "string").map((value) => value.toLowerCase());
  return within.some((part) => names.includes(part));
}

/** Source.isHere: words that mean wherever the user is, rather than a place. */
export function isHere(place: string): boolean {
  return ["", "current location", "my location", "here", "near me", "where i am", "current", "me"].includes(place.toLowerCase().trim());
}

async function getJSON(url: string, fetcher: Fetch): Promise<JSONObject | null> {
  try {
    const response = await fetcher(url, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" }, signal: AbortSignal.timeout(10_000) });
    if (!response.ok) {
      await response.body?.cancel();
      return null;
    }
    const body: unknown = await response.json();
    return isObject(body) ? body : null;
  } catch {
    return null;
  }
}

// MARK: - The weather

/** What WMO's weather codes mean, as WeatherKit's conditions read, for the summary. */
const CONDITIONS: Record<number, string> = {
  0: "Clear", 1: "Mostly Clear", 2: "Partly Cloudy", 3: "Cloudy", 45: "Foggy", 48: "Foggy",
  51: "Drizzle", 53: "Drizzle", 55: "Drizzle", 56: "Freezing Drizzle", 57: "Freezing Drizzle",
  61: "Rain", 63: "Rain", 65: "Heavy Rain", 66: "Freezing Rain", 67: "Freezing Rain",
  71: "Snow", 73: "Snow", 75: "Heavy Snow", 77: "Flurries", 80: "Rain", 81: "Rain", 82: "Heavy Rain",
  85: "Snow", 86: "Heavy Snow", 95: "Thunderstorms", 96: "Thunderstorms", 99: "Thunderstorms",
};

const HOURLY = ["temperature_2m", "apparent_temperature", "precipitation_probability", "relative_humidity_2m", "wind_speed_10m", "uv_index", "cloud_cover", "weather_code"];
const CURRENT = ["temperature_2m", "apparent_temperature", "relative_humidity_2m", "wind_speed_10m", "uv_index", "cloud_cover", "weather_code"];
const DAILY = ["temperature_2m_max", "temperature_2m_min", "precipitation_probability_max", "precipitation_sum", "wind_speed_10m_max", "uv_index_max", "weather_code"];

/** WeatherProvider: the weather for a place and a day, now, at an hour, or for the whole day, up
 * to ten days ahead. Temperatures in °C, speeds in km/h, rain in mm, chances, humidity and cloud
 * as percentages, the UV index as a whole number: the fields and meanings WeatherKit's reading
 * gives on the phone. */
async function readWeather(source: Source, context: LiveContext): Promise<Reading> {
  const parameter = (name: string) => source.parameters[name] ?? "";
  const place = await findPlace(parameter("place"), context.here, context.fetch, context.reader.language);
  const now = context.now();
  const start = today(now, place.timeZone);
  const day = liveDay(parameter("day"), start);
  if (day === null) throw new LiveError("notFound", `Dream can't tell which day "${parameter("day")}" is.`);
  const ahead = Math.round((day - start) / DAY);
  if (ahead < 0 || ahead > 9) throw new LiveError("notFound", "Forecasts only reach 10 days ahead.");
  const at = minutes(parameter("time"));
  const isToday = ahead === 0;

  const url = new URL("https://api.open-meteo.com/v1/forecast");
  const query: Record<string, string> = {
    latitude: String(place.latitude),
    longitude: String(place.longitude),
    timezone: place.timeZone,
    start_date: isoDay(day),
    end_date: isoDay(day),
    current: CURRENT.join(","),
    hourly: HOURLY.join(","),
    daily: DAILY.join(","),
    temperature_unit: "celsius",
    wind_speed_unit: "kmh",
    precipitation_unit: "mm",
  };
  for (const [name, value] of Object.entries(query)) url.searchParams.set(name, value);
  const answer = await getJSON(url.href, context.fetch);
  if (!answer) throw new LiveError("unavailable", "The weather isn't available right now.");
  const daily = isObject(answer.daily) ? answer.daily : {};
  const dayAt = Array.isArray(daily.time) ? daily.time.indexOf(isoDay(day)) : -1;
  if (dayAt < 0) throw new LiveError("unavailable", "There's no forecast for that day yet.");
  const daysValue = (name: string) => (Array.isArray(daily[name]) ? (daily[name] as unknown[])[dayAt] : undefined);
  const current = isObject(answer.current) ? answer.current : {};
  const hourly = isObject(answer.hourly) ? answer.hourly : {};
  let hour: number | null = null;
  if (at !== null && Array.isArray(hourly.time)) {
    const wanted = day + at * 60_000;
    let best = Infinity;
    (hourly.time as unknown[]).forEach((time, index) => {
      const when = typeof time === "string" ? Date.parse(`${time}Z`) : NaN;
      if (Number.isFinite(when) && Math.abs(when - wanted) < best) {
        best = Math.abs(when - wanted);
        hour = index;
      }
    });
  }
  const hoursValue = (name: string) => (hour !== null && Array.isArray(hourly[name]) ? (hourly[name] as unknown[])[hour] : undefined);

  const locale = localeOf(context.reader);
  const clock = (offset: number) => new Intl.DateTimeFormat(locale, { timeZone: "UTC", hour: "numeric", minute: "2-digit" }).format(day + offset * 60_000);
  const moment = at !== null ? `at ${clock(at)}` : isToday ? "now" : "during the day";
  const date = new Intl.DateTimeFormat(locale, { timeZone: "UTC", weekday: "long", day: "numeric", month: "long" }).format(day);
  const named = isToday ? "today" : date;
  const when = at !== null ? `${named} at ${clock(at)}` : isToday ? "now and today" : date;

  const fields: SourceField[] = [];
  const add = (name: string, value: unknown, unit: string, format: SourceField["format"], meaning: string) => {
    if (typeof value !== "number" || !Number.isFinite(value)) return;
    fields.push({ name, value, unit, format, meaning });
  };
  const uv = (value: unknown) => (typeof value === "number" ? round(value) : value);
  add("high", daysValue("temperature_2m_max"), "°C", "number", "the day's highest temperature");
  add("low", daysValue("temperature_2m_min"), "°C", "number", "the day's lowest temperature");
  if (hour !== null) {
    add("temperature", hoursValue("temperature_2m"), "°C", "number", `the temperature ${moment}`);
    add("feelsLike", hoursValue("apparent_temperature"), "°C", "number", `what it feels like ${moment}`);
    add("rainChance", hoursValue("precipitation_probability"), "", "percent", `the chance of rain ${moment}`);
    add("humidity", hoursValue("relative_humidity_2m"), "", "percent", `humidity ${moment}`);
    add("windSpeed", hoursValue("wind_speed_10m"), "km/h", "number", `wind speed ${moment}`);
    add("uvIndex", uv(hoursValue("uv_index")), "", "integer", `the UV index ${moment}`);
    add("cloudCover", hoursValue("cloud_cover"), "", "percent", `cloud cover ${moment}`);
  } else if (isToday) {
    add("temperature", current.temperature_2m, "°C", "number", "the temperature now");
    add("feelsLike", current.apparent_temperature, "°C", "number", "what it feels like now");
    add("rainChance", daysValue("precipitation_probability_max"), "", "percent", "the chance of rain today");
    add("humidity", current.relative_humidity_2m, "", "percent", "humidity now");
    add("windSpeed", current.wind_speed_10m, "km/h", "number", "wind speed now");
    add("uvIndex", uv(current.uv_index), "", "integer", "the UV index now");
    add("cloudCover", current.cloud_cover, "", "percent", "cloud cover now");
  } else {
    add("rainChance", daysValue("precipitation_probability_max"), "", "percent", "the chance of rain during the day");
    add("windSpeed", daysValue("wind_speed_10m_max"), "km/h", "number", "wind speed during the day");
    add("uvIndex", uv(daysValue("uv_index_max")), "", "integer", "the day's highest UV index");
  }
  add("rainAmount", daysValue("precipitation_sum"), "mm", "number", "how much rain is expected during the day");
  const code = hour !== null ? hoursValue("weather_code") : isToday ? current.weather_code : daysValue("weather_code");
  const condition = typeof code === "number" ? (CONDITIONS[code] ?? "Mixed") : "Mixed";
  return { fields, summary: `${place.name}, ${when}: ${condition}` };
}

// MARK: - Exchange rates

/** Rates from one base currency, and when they were set (RateTable). */
interface RateTable {
  rates: Record<string, number>;
  updated: number;
  nextUpdate: number;
}

/** Rate tables by base currency, kept until the service says the next update is due, as its
 * terms ask: rates are cached rather than fetched on every page. */
const rateTables = new Map<string, RateTable>();

async function rateTable(base: string, context: LiveContext): Promise<RateTable> {
  const kept = rateTables.get(base);
  if (kept && kept.nextUpdate > context.now()) return kept;
  try {
    const table = await fetchRates(base, context);
    rateTables.set(base, table);
    return table;
  } catch (error) {
    // Yesterday's rates beat none; the screen shows how old they are.
    if (kept) return kept;
    throw error;
  }
}

async function fetchRates(base: string, context: LiveContext): Promise<RateTable> {
  if (!/^[A-Za-z]+$/.test(base)) throw new LiveError("notFound", `${base} isn't a currency code.`);
  let body: unknown;
  try {
    const response = await context.fetch(`https://open.er-api.com/v6/latest/${base}`, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" }, signal: AbortSignal.timeout(10_000) });
    body = await response.json().catch(() => null);
  } catch {
    throw new LiveError("unavailable", "Exchange rates aren't available right now.");
  }
  if (!isObject(body) || body.result !== "success" || !isObject(body.rates)) throw new LiveError("notFound", `There are no exchange rates for ${base}.`);
  const rates: Record<string, number> = {};
  for (const [code, rate] of Object.entries(body.rates)) if (typeof rate === "number" && Number.isFinite(rate)) rates[code] = rate;
  const now = context.now();
  const updated = typeof body.time_last_update_unix === "number" ? body.time_last_update_unix * 1000 : now;
  const next = typeof body.time_next_update_unix === "number" ? body.time_next_update_unix * 1000 : updated + DAY;
  return { rates, updated, nextUpdate: Math.max(next, now + 15 * 60_000) };
}

/** ExchangeRateProvider: how many of one currency make one of another; to the user's own when
 * it doesn't say. */
async function readRate(source: Source, context: LiveContext): Promise<Reading> {
  const code = (text: string | undefined) => (text ?? "").trim().toUpperCase();
  const from = code(source.parameters.from);
  const to = code(source.parameters.to) || context.reader.currency.toUpperCase();
  if ([...from].length !== 3 || [...to].length !== 3) throw new LiveError("notFound", "Exchange rates need two currency codes, like USD and INR.");
  const table = await rateTable(from, context);
  const rate = table.rates[to];
  if (rate === undefined) throw new LiveError("notFound", `There's no rate from ${from} to ${to}.`);
  const name = (currency: string) => {
    try {
      return new Intl.DisplayNames(["en"], { type: "currency" }).of(currency) ?? currency;
    } catch {
      return currency;
    }
  };
  let shown: string;
  try {
    shown = new Intl.NumberFormat(localeOf(context.reader), { minimumSignificantDigits: 1, maximumSignificantDigits: 6 }).format(rate);
  } catch {
    shown = String(rate);
  }
  return {
    fields: [{ name: "rate", value: rate, unit: "", format: "number", meaning: `how many ${to} one ${from} buys` }],
    summary: `1 ${name(from)} is ${shown} ${name(to)}`,
  };
}

// MARK: - Reading

/** How long a reading stays current, by kind (LiveProvider.freshness). */
const FRESHNESS: Record<string, number> = { weather: 15 * 60_000, exchangeRate: 60 * 60_000 };
const PROVIDERS: Record<string, (source: Source, context: LiveContext) => Promise<Reading>> = { weather: readWeather, exchangeRate: readRate };

/** Recent readings by what was asked (LiveCache), so asking twice in quick succession reads
 * once. Where the user is counts as part of what was asked. */
const readings = new Map<string, { reading: Reading; at: number }>();
const inFlight = new Map<string, Promise<Reading>>();

async function read(source: Source, context: LiveContext): Promise<Reading> {
  const provider = PROVIDERS[source.kind];
  if (!provider) throw new LiveError("unavailable", `Dream can't read ${source.kind} here.`);
  const here = Object.values(source.parameters).some(isHere) && context.here ? `@${context.here.latitude},${context.here.longitude}` : "";
  const key = `${source.kind}|${JSON.stringify(Object.entries(source.parameters).sort(([a], [b]) => (a < b ? -1 : 1)))}|${context.reader.currency}|${localeOf(context.reader)}${here}`;
  const kept = readings.get(key);
  if (kept && context.now() - kept.at < (FRESHNESS[source.kind] ?? 0)) return kept.reading;
  const running = inFlight.get(key);
  if (running) return running;
  const reading = provider(source, context);
  inFlight.set(key, reading);
  try {
    const fresh = await reading;
    if (readings.size > 500) readings.delete(readings.keys().next().value!);
    readings.set(key, { reading: fresh, at: context.now() });
    return fresh;
  } finally {
    inFlight.delete(key);
  }
}

/** Forgets every reading, place and rate kept, for tests. */
export function forgetLiveReadings(): void {
  readings.clear();
  placesFound.clear();
  rateTables.clear();
}

/** The sources fetched while writing a page: what it may bind live inputs to (LiveLog). A change
 * starts with the sources the page already has. */
export class LiveLog {
  private declared: Source[];

  constructor(keeping: Source[] = []) {
    this.declared = keeping.map((source) => ({ ...source }));
  }

  /** A source with what it read. One fetched again under the same name replaces the first. */
  declare(source: Source, fields: SourceField[]): void {
    this.declared = this.declared.filter((other) => other.name !== source.name);
    this.declared.push({ ...source, fields });
  }

  get sources(): Source[] {
    return this.declared.map((source) => ({ ...source }));
  }
}

/** What the phone answered for one of its tools (contract.ts, DeviceToolOutput). */
export interface DeviceAnswer {
  output: string;
  source?: Source;
  service?: string;
}

/** What the live tool needs for one page. */
export interface LiveContext {
  fetch: Fetch;
  now(): number;
  here: Here | null;
  reader: Reader;
  /** Asks the phone to run its own live tool, for a route; null when it didn't offer one. The
   * answer is null when it didn't answer in time. */
  phone: ((argumentsJSON: string) => Promise<DeviceAnswer | null>) | null;
}

/** SourceReading.described(as:): each field by its full name, in the reader's units, with what it
 * means, then how to show them. */
export function described(generation: Generation, name: string, reading: Reading, reader: Reader): string {
  const text = generation.toolText.live;
  const lines = [fill(text.header, { name, summary: reading.summary })];
  asReader({ currency: reader.currency, measurementSystem: reader.measurementSystem, language: reader.language, region: reader.region }, () => {
    for (const field of reading.fields) {
      const local = field.unit ? LiveUnits.local(field.value, field.unit) : { value: field.value, unit: "" };
      const shown = field.format === "percent" ? `${plain(round(local.value * 10) / 10)}%` : `${plain(round(local.value * 100) / 100)}${local.unit ? ` ${local.unit}` : ""}`;
      lines.push(fill(field.meaning ? text.field : text.fieldPlain, { name, field: field.name, value: shown, meaning: field.meaning }));
    }
  });
  lines.push(fill(text.closing, { name, field: reading.fields[0]?.name ?? "value" }));
  return lines.join("\n");
}

/** A Source as the phone sent it back for a route it read, checked, or null. */
export function sourceOf(value: unknown): Source | null {
  if (!isObject(value) || typeof value.name !== "string" || !value.name || typeof value.kind !== "string" || !isObject(value.parameters) || !Array.isArray(value.fields)) return null;
  const parameters: Record<string, string> = {};
  for (const [key, parameter] of Object.entries(value.parameters)) if (typeof parameter === "string") parameters[key] = parameter;
  const formats = new Set(["number", "integer", "currency", "percent", "toggle", "choice"]);
  const fields = value.fields.filter(isObject).flatMap((field): SourceField[] =>
    typeof field.name === "string" && field.name && typeof field.value === "number" && Number.isFinite(field.value)
      ? [{ name: field.name, value: field.value, unit: typeof field.unit === "string" ? field.unit : "", format: formats.has(String(field.format)) ? (field.format as SourceField["format"]) : "number", meaning: typeof field.meaning === "string" ? field.meaning : "" }]
      : [],
  );
  const source: Source = { name: identifier(value.name), kind: value.kind, parameters, fields };
  if (Array.isArray(value.lists)) {
    source.lists = value.lists.filter(isObject).flatMap((list) => (typeof list.name === "string" && Array.isArray(list.keys) && typeof list.count === "number" ? [{ name: list.name, keys: list.keys.filter((key): key is string => typeof key === "string"), count: list.count }] : []));
  }
  return source;
}

/** LiveTool.call: reads the weather, an exchange rate or a route while a page is written, and
 * declares it as a source the page keeps current. `note` hears a line for the log. */
export async function liveCall(generation: Generation, args: JSONObject, argumentsJSON: string, log: LiveLog, context: LiveContext, note: (line: string) => void): Promise<string> {
  const text = generation.toolText.live;
  const field = (name: string) => (typeof args[name] === "string" ? (args[name] as string) : "");
  const kind = field("kind");
  const name = identifier(field("name") || kind);
  let parameters: Record<string, string>;
  switch (kind) {
    case "weather":
      parameters = { place: field("place"), day: field("day"), time: field("time") };
      break;
    case "exchangeRate":
      parameters = { from: field("from"), to: field("to") };
      break;
    case "route":
      parameters = { from: field("from"), to: field("to"), travel: field("travel") || "driving" };
      break;
    default:
      parameters = {};
  }
  parameters = Object.fromEntries(Object.entries(parameters).map(([key, value]) => [key, value.trim()]).filter(([, value]) => value !== ""));
  // Where the user is, said one way, so the page and the cache agree on it.
  for (const key of ["place", "from"]) if (key in parameters && isHere(parameters[key])) parameters[key] = "current location";
  if (kind === "weather" && !("place" in parameters)) parameters.place = "current location";
  if (kind === "route" && !("from" in parameters)) parameters.from = "current location";
  const source: Source = { name, kind, parameters, fields: [] };
  const asked = Object.entries(parameters).sort(([a], [b]) => (a < b ? -1 : 1)).map(([key, value]) => `${key} ${value}`).join(", ");

  // A travel time is the phone's: its own live tool reads it from Apple Maps.
  if (kind === "route" && context.phone) {
    const answer = await context.phone(argumentsJSON);
    if (!answer) {
      note(`Live: ${name}, ${kind} (${asked}) failed: the phone didn't answer`);
      return fill(text.failed, { message: "Dream couldn't reach the phone to read this." });
    }
    if (answer.source) log.declare(answer.source, answer.source.fields);
    note(`Live: ${name}, ${kind} (${asked}), on the phone${answer.source ? "" : ", which said what it read but not as a source"}`);
    return answer.output;
  }
  try {
    const reading = await read(source, context);
    log.declare(source, reading.fields);
    note(`Live: ${name}, ${kind} (${asked})`);
    return `${described(generation, name, reading, context.reader)}`;
  } catch (error) {
    const message = error instanceof LiveError ? error.message : "It couldn't be read.";
    if (!(error instanceof LiveError)) console.error("Live source failed", error instanceof Error ? error.name : typeof error);
    note(`Live: ${name}, ${kind} (${asked}) failed: ${message}`);
    return fill(text.failed, { message });
  }
}
