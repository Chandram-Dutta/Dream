// Live data while a page is written on the server, ported from the app's live tool
// (Dream/Generation/LiveTool.swift, LiveSources.swift) and its providers, so a page made here
// declares the same sources a page made on the phone does. The phone reads every source again
// itself (WeatherKit, MapKit, ExchangeRate-API), so what's kept on the page is exactly what the
// app's providers write: the same field names, metric units, formats and meanings
// (Dream/Engine/Live.swift's Source and SourceField).
//
//   weather       Apple Weather (WeatherKit, weatherkit.ts), as WeatherProvider reads it
//                 (LiveWeather.swift), with the same fields made from the same values. Open-Meteo
//                 stands in, with the fields made the same way, until WeatherKit's secrets are
//                 set and whenever it fails; the log says which it was. Places by name come from
//                 Open-Meteo's geocoding, no key. "current location" is where the phone says the
//                 user is, when they've let it (ComposeRequest.here), or else where Cloudflare
//                 places the request. A place's day is the place's own.
//   exchangeRate  open.er-api.com, as LiveRates.swift reads it, each base kept until the service
//                 says its next update is due.
//
// A reading carries the credit its provider's terms ask for, as the phone's does (LiveCredit):
// the Apple Weather mark and its legal link, or a link. The page keeps only the source, which has
// no credit, as the app's hasn't: the phone reads it again and shows its own reading's credit
// beside the values (LiveStamp.swift).
//
// A travel time is the phone's to read (Apple Maps), with a tool of its own (`travel`, in its
// deviceTools): the server's live tool doesn't offer routes, and says it can't read one.
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
import type { ComposeRequest } from "./contract";
import { fill, type Generation } from "./prompts";
import { WeatherKitFailure, weatherKitForecast, type WeatherKitConfig } from "./weatherkit";

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

/** Credit a provider's terms ask for, wherever its values appear (LiveCredit). */
export type LiveCredit = { kind: "appleWeather"; legal: string } | { kind: "link"; text: string; url: string };

/** The Apple Weather mark and a link to its legal attribution, which WeatherKit requires: the
 * page WeatherCredit links to when WeatherKit doesn't name one. */
export const APPLE_WEATHER: LiveCredit = { kind: "appleWeather", legal: "https://weatherkit.apple.com/legal-attribution.html" };
/** Open-Meteo's data is CC BY 4.0, credited with a link. */
export const OPEN_METEO: LiveCredit = { kind: "link", text: "Weather data by Open-Meteo.com", url: "https://open-meteo.com/" };
const EXCHANGE_RATE_API: LiveCredit = { kind: "link", text: "Rates by Exchange Rate API", url: "https://www.exchangerate-api.com" };

/** What a source read (SourceReading): its fields, a summary for the model, who it's from, and a
 * line for the log saying where it came from, if there's more to say than the source. */
export interface Reading {
  fields: SourceField[];
  summary: string;
  credit?: LiveCredit;
  note?: string;
}

/** Where the user is, for the weather "here" (Places.here): where the phone says, or where
 * Cloudflare places the request (`hereFor`). */
export interface Here {
  latitude: number;
  longitude: number;
  /** What to call it, like Bengaluru. */
  city?: string;
  /** Where days start and end there, like Asia/Kolkata. */
  timeZone?: string;
  /** Who said so: the phone, or the network the request came over. */
  from?: "phone" | "network";
}

/** Where the user is, for the weather "here": where the phone says they are, when they've let it
 * (ComposeRequest.here), or else where Cloudflare places the request; null when neither knows.
 * It's called by its town, as the phone calls where it is. Its days are the phone's, or failing
 * that the network's. */
export function hereFor(phone: ComposeRequest["here"], network: Here | null): Here | null {
  if (!phone) return network ? { ...network, from: "network" } : null;
  const town = phone.name.split(",")[0]?.trim();
  const timeZone = phone.timeZone ?? network?.timeZone;
  return { latitude: phone.latitude, longitude: phone.longitude, ...(town ? { city: town } : {}), ...(timeZone ? { timeZone } : {}), from: "phone" };
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

/** How far a time zone's clocks are ahead of UTC at an instant, in milliseconds. */
function offsetAt(time: number, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: zone(timeZone), hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric" }).formatToParts(time);
  const part = (type: string) => Number(parts.find((item) => item.type === type)?.value);
  return Date.UTC(part("year"), part("month") - 1, part("day"), part("hour"), part("minute"), part("second")) - Math.floor(time / 1000) * 1000;
}

/** The instant a day (as `today` gives one) starts in a time zone: Calendar.startOfDay, in the
 * place's calendar. */
export function startOfDay(day: number, timeZone: string): number {
  return day - offsetAt(day - offsetAt(day, timeZone), timeZone);
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
  /** Where the user is, and who said so. */
  here?: Here["from"];
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
    return { name: here.city || "your location", latitude: here.latitude, longitude: here.longitude, timeZone: zone(here.timeZone), here: here.from ?? "network" };
  }
  // The model often names the user's own town, as the phone told it, rather than saying "here":
  // that's where the phone is, with no search. A search by name once missed a city of a million
  // (Dombivli) and the page fell back to the next big city.
  if (here?.from === "phone" && here.city && sameTown(name, here.city)) {
    return { name: here.city.split(",")[0].trim(), latitude: here.latitude, longitude: here.longitude, timeZone: zone(here.timeZone) };
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

/** Whether a place's name is the user's own town: the same first part, ignoring case and accents. */
function sameTown(name: string, city: string): boolean {
  const town = (text: string) => text.split(",")[0].normalize("NFD").replace(/\p{M}/gu, "").trim().toLowerCase();
  return town(name) !== "" && town(name) === town(city);
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

/** A moment's weather, as the phone's Forecast.reading reads WeatherKit's CurrentWeather or
 * HourWeather: temperatures in °C, the wind in km/h, chances, humidity and cloud cover as
 * percentages. Each is missing where the provider gave none. */
export interface MomentConditions {
  temperature?: number;
  feelsLike?: number;
  /** An hour's; the weather now has none. */
  rainChance?: number;
  humidity?: number;
  windSpeed?: number;
  uvIndex?: number;
  cloudCover?: number;
  /** As WeatherCondition describes itself, like Mostly Cloudy. */
  condition: string;
}

/** A day's weather, as Forecast.reading reads WeatherKit's DayWeather: °C, km/h, a percentage, and
 * the day's precipitation in mm. */
export interface DayConditions {
  high?: number;
  low?: number;
  rainChance?: number;
  windSpeed?: number;
  uvIndex?: number;
  rainAmount?: number;
  condition: string;
}

/** One request's forecast (LiveWeather.swift's Forecast): the place, the day, the minute of it
 * asked for if one was, and whose way of writing times it's said in. */
interface Asked {
  place: Place;
  /** The day, as `today` gives one. */
  day: number;
  /** Minutes into the day. */
  at: number | null;
  isToday: boolean;
  locale: string;
}

/** Forecast.reading: the fields the phone makes from WeatherKit's weather now, the hour asked for
 * and the day, in its order, with its units, formats and meanings. */
function forecastReading(asked: Asked, current: MomentConditions | null, hour: MomentConditions | null, day: DayConditions, credit: LiveCredit, from: string): Reading {
  const { place, at, isToday } = asked;
  const clock = (offset: number) => new Intl.DateTimeFormat(asked.locale, { timeZone: "UTC", hour: "numeric", minute: "2-digit" }).format(asked.day + offset * 60_000);
  const moment = at !== null ? `at ${clock(at)}` : isToday ? "now" : "during the day";
  const date = new Intl.DateTimeFormat(asked.locale, { timeZone: "UTC", weekday: "long", day: "numeric", month: "long" }).format(asked.day);
  const named = isToday ? "today" : date;
  const when = at !== null ? `${named} at ${clock(at)}` : isToday ? "now and today" : date;

  const fields: SourceField[] = [];
  const add = (name: string, value: number | undefined, unit: string, format: SourceField["format"], meaning: string) => {
    if (value === undefined || !Number.isFinite(value)) return;
    fields.push({ name, value, unit, format, meaning });
  };
  // A whole number, as WeatherKit's UVIndex has it.
  const uv = (value: number | undefined) => (value === undefined ? undefined : round(value));
  add("high", day.high, "°C", "number", "the day's highest temperature");
  add("low", day.low, "°C", "number", "the day's lowest temperature");
  if (hour) {
    add("temperature", hour.temperature, "°C", "number", `the temperature ${moment}`);
    add("feelsLike", hour.feelsLike, "°C", "number", `what it feels like ${moment}`);
    add("rainChance", hour.rainChance, "", "percent", `the chance of rain ${moment}`);
    add("humidity", hour.humidity, "", "percent", `humidity ${moment}`);
    add("windSpeed", hour.windSpeed, "km/h", "number", `wind speed ${moment}`);
    add("uvIndex", uv(hour.uvIndex), "", "integer", `the UV index ${moment}`);
    add("cloudCover", hour.cloudCover, "", "percent", `cloud cover ${moment}`);
  } else if (isToday) {
    add("temperature", current?.temperature, "°C", "number", "the temperature now");
    add("feelsLike", current?.feelsLike, "°C", "number", "what it feels like now");
    add("rainChance", day.rainChance, "", "percent", "the chance of rain today");
    add("humidity", current?.humidity, "", "percent", "humidity now");
    add("windSpeed", current?.windSpeed, "km/h", "number", "wind speed now");
    add("uvIndex", uv(current?.uvIndex), "", "integer", "the UV index now");
    add("cloudCover", current?.cloudCover, "", "percent", "cloud cover now");
  } else {
    add("rainChance", day.rainChance, "", "percent", "the chance of rain during the day");
    add("windSpeed", day.windSpeed, "km/h", "number", "wind speed during the day");
    add("uvIndex", uv(day.uvIndex), "", "integer", "the day's highest UV index");
  }
  add("rainAmount", day.rainAmount, "mm", "number", "how much rain is expected during the day");
  const condition = hour?.condition ?? (isToday ? current?.condition : day.condition) ?? "Mixed";
  const where = place.here === "phone" ? ", where the phone is" : place.here === "network" ? ", where the request came from" : "";
  return { fields, summary: `${place.name}, ${when}: ${condition}`, credit, note: `Weather from ${from}${where}` };
}

let unconfigured = false;

/** WeatherProvider: the weather for a place and a day, now, at an hour, or for the whole day, up
 * to ten days ahead, from Apple Weather as the phone reads it, or from Open-Meteo when WeatherKit
 * isn't set up or fails. */
async function readWeather(source: Source, context: LiveContext): Promise<Reading> {
  const parameter = (name: string) => source.parameters[name] ?? "";
  const place = await findPlace(parameter("place"), context.here, context.fetch, context.reader.language);
  const start = today(context.now(), place.timeZone);
  const day = liveDay(parameter("day"), start);
  if (day === null) throw new LiveError("notFound", `Dream can't tell which day "${parameter("day")}" is.`);
  const ahead = Math.round((day - start) / DAY);
  if (ahead < 0 || ahead > 9) throw new LiveError("notFound", "Forecasts only reach 10 days ahead.");
  const asked: Asked = { place, day, at: minutes(parameter("time")), isToday: ahead === 0, locale: localeOf(context.reader) };

  let why = "Apple Weather isn't set up";
  if (context.weatherKit) {
    try {
      return await fromAppleWeather(asked, context.weatherKit, context);
    } catch (error) {
      if (error instanceof LiveError) throw error;
      why = error instanceof WeatherKitFailure ? `Apple Weather ${error.message}` : `Apple Weather failed (${error instanceof Error ? error.name : typeof error})`;
      console.warn(`The weather is from Open-Meteo: ${why}.`);
    }
  } else if (!unconfigured) {
    unconfigured = true;
    console.log("The weather is from Open-Meteo: WEATHERKIT_KEY, WEATHERKIT_KEY_ID and WEATHERKIT_TEAM_ID aren't set.");
  }
  return fromOpenMeteo(asked, context, `Open-Meteo, since ${why}`);
}

/** The forecast from WeatherKit, asked for as the phone asks WeatherService: the day from its
 * start to the next day's where the place is, its hours when an hour was asked for, and the
 * weather now for today. */
async function fromAppleWeather(asked: Asked, config: WeatherKitConfig, context: LiveContext): Promise<Reading> {
  const { place } = asked;
  const start = startOfDay(asked.day, place.timeZone);
  const end = startOfDay(asked.day + DAY, place.timeZone);
  const at = asked.at === null ? null : start + asked.at * 60_000;
  const forecast = await weatherKitForecast(config, { latitude: place.latitude, longitude: place.longitude, timeZone: place.timeZone, start, end, at, current: asked.isToday }, context.fetch, context.now());
  if (!forecast.day) throw new LiveError("unavailable", "There's no forecast for that day yet.");
  return forecastReading(asked, forecast.current, forecast.hour, forecast.day, APPLE_WEATHER, "Apple Weather");
}

/** The forecast from Open-Meteo, read as WeatherKit's would be. `from` says why it's Open-Meteo's. */
async function fromOpenMeteo(asked: Asked, context: LiveContext, from: string): Promise<Reading> {
  const { place, day, at, isToday } = asked;
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

  const number = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);
  const condition = (code: unknown) => (typeof code === "number" ? (CONDITIONS[code] ?? "Mixed") : "Mixed");
  const now: MomentConditions | null = isToday
    ? {
        temperature: number(current.temperature_2m),
        feelsLike: number(current.apparent_temperature),
        humidity: number(current.relative_humidity_2m),
        windSpeed: number(current.wind_speed_10m),
        uvIndex: number(current.uv_index),
        cloudCover: number(current.cloud_cover),
        condition: condition(current.weather_code),
      }
    : null;
  const atHour: MomentConditions | null = hour !== null
    ? {
        temperature: number(hoursValue("temperature_2m")),
        feelsLike: number(hoursValue("apparent_temperature")),
        rainChance: number(hoursValue("precipitation_probability")),
        humidity: number(hoursValue("relative_humidity_2m")),
        windSpeed: number(hoursValue("wind_speed_10m")),
        uvIndex: number(hoursValue("uv_index")),
        cloudCover: number(hoursValue("cloud_cover")),
        condition: condition(hoursValue("weather_code")),
      }
    : null;
  const whole: DayConditions = {
    high: number(daysValue("temperature_2m_max")),
    low: number(daysValue("temperature_2m_min")),
    rainChance: number(daysValue("precipitation_probability_max")),
    windSpeed: number(daysValue("wind_speed_10m_max")),
    uvIndex: number(daysValue("uv_index_max")),
    rainAmount: number(daysValue("precipitation_sum")),
    condition: condition(daysValue("weather_code")),
  };
  return forecastReading(asked, now, atHour, whole, OPEN_METEO, from);
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
    credit: EXCHANGE_RATE_API,
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

/** LiveSources.read: what a source reads now, or what it read moments ago. */
export async function readSource(source: Source, context: LiveContext): Promise<Reading> {
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

/** Forgets every reading, place and rate kept, and that the weather's provider was logged, for
 * tests. */
export function forgetLiveReadings(): void {
  readings.clear();
  placesFound.clear();
  rateTables.clear();
  unconfigured = false;
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
  /** How to reach Apple Weather; without it, the weather is Open-Meteo's. */
  weatherKit?: WeatherKitConfig | null;
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

/** LiveTool.call: reads the weather or an exchange rate while a page is written, and declares it
 * as a source the page keeps current. `note` hears a line for the log. */
export async function liveCall(generation: Generation, args: JSONObject, log: LiveLog, context: LiveContext, note: (line: string) => void): Promise<string> {
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
  try {
    const reading = await readSource(source, context);
    log.declare(source, reading.fields);
    note(`Live: ${name}, ${kind} (${asked})`);
    if (reading.note) note(reading.note);
    return `${described(generation, name, reading, context.reader)}`;
  } catch (error) {
    const message = error instanceof LiveError ? error.message : "It couldn't be read.";
    if (!(error instanceof LiveError)) console.error("Live source failed", error instanceof Error ? error.name : typeof error);
    note(`Live: ${name}, ${kind} (${asked}) failed: ${message}`);
    return fill(text.failed, { message });
  }
}
