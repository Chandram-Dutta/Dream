// Apple Weather for pages made on the server: WeatherKit's REST API, the service the phone's own
// WeatherProvider reads (Dream/Generation/LiveWeather.swift), so the values a page is written with
// are the ones the phone refreshes it to. This asks for a place's forecast and reads its answer as
// the WeatherKit values the phone's Forecast.reading takes, in the units it converts them to;
// live.ts makes the fields from them, as the phone does.
//
//   GET https://weatherkit.apple.com/api/v1/weather/en/{latitude}/{longitude}
//       ?dataSets=currentWeather,forecastDaily,forecastHourly&timezone=…&dailyStart=…
//
// Every request carries a token: an ES256 JWT signed with Dream's WeatherKit key, from the
// secrets WEATHERKIT_KEY (the text of its .p8 file), WEATHERKIT_KEY_ID and WEATHERKIT_TEAM_ID,
// for the app's bundle ID, which WeatherKit's service is enabled for. A token is good for an hour
// and is reused for the first half of it. Until the secrets are set, and whenever WeatherKit
// fails, the weather comes from Open-Meteo instead (live.ts), and the log says so. Nothing about
// the request, and never the key or a token, is logged.
//
// Only types are imported besides apple.ts, so test/weather.mjs runs it in Node with a key of its
// own and a stand-in for Apple.

import { signES256 } from "../apple";
import type { DayConditions, MomentConditions } from "./live";

type JSONObject = Record<string, unknown>;
type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

export interface WeatherKitEnv {
  /** Secret. Dream's WeatherKit key: the text of its .p8 file. */
  WEATHERKIT_KEY?: string;
  /** Secret. That key's ID, from the developer portal. */
  WEATHERKIT_KEY_ID?: string;
  /** Secret. The developer team the key belongs to. */
  WEATHERKIT_TEAM_ID?: string;
}

/** The app's bundle ID, which WeatherKit's service is enabled for and every token is for. */
export const SERVICE = "xyz.onlychan.Dream";
export const WEATHERKIT = "https://weatherkit.apple.com";
const USER_AGENT = "Dream/0.1 (Dream's server; +https://dream.onlychan.xyz/support)";

/** How to reach WeatherKit, or null while the secrets aren't set. */
export interface WeatherKitConfig {
  key: string;
  keyID: string;
  teamID: string;
}

export function weatherKitConfig(env: WeatherKitEnv): WeatherKitConfig | null {
  const key = env.WEATHERKIT_KEY?.trim();
  const keyID = env.WEATHERKIT_KEY_ID?.trim();
  const teamID = env.WEATHERKIT_TEAM_ID?.trim();
  return key && keyID && teamID ? { key, keyID, teamID } : null;
}

// MARK: - The token

/** A token lasts an hour, and is made again once it's half an hour old, so one is never close to
 * running out when it's used. */
const LIFETIME = 60 * 60;
const REUSE = 30 * 60;

let signed: { keyID: string; teamID: string; iat: number; token: string } | null = null;

/** The token for WeatherKit's requests: ES256, signed with Dream's WeatherKit key. */
export async function weatherKitToken(config: WeatherKitConfig, now = Date.now()): Promise<string> {
  const at = Math.floor(now / 1000);
  if (signed && signed.keyID === config.keyID && signed.teamID === config.teamID && at >= signed.iat && at - signed.iat < REUSE) return signed.token;
  const header = { alg: "ES256", kid: config.keyID, id: `${config.teamID}.${SERVICE}` };
  const claims = { iss: config.teamID, iat: at, exp: at + LIFETIME, sub: SERVICE };
  const token = await signES256(config.key, header, claims);
  signed = { keyID: config.keyID, teamID: config.teamID, iat: at, token };
  return token;
}

/** Forgets the token kept, so the next request signs a new one: after WeatherKit refuses one, and
 * in tests. */
export function forgetWeatherKitToken(): void {
  signed = null;
}

// MARK: - The forecast

/** Why WeatherKit couldn't give a forecast, in a few words for the log, like "answered 401". */
export class WeatherKitFailure extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WeatherKitFailure";
  }
}

/** One request's forecast, as the phone asks WeatherService for it: the place, its time zone, and
 * the day as instants where the place is. `at`, an instant in the day, also asks for its hours;
 * `current` for the weather now. */
export interface WeatherKitAsk {
  latitude: number;
  longitude: number;
  timeZone: string;
  start: number;
  end: number;
  at: number | null;
  current: boolean;
}

/** What Forecast.reading reads: the weather now, the hour nearest `at`, and the day, each null
 * when it wasn't asked for or WeatherKit had none. */
export interface WeatherKitForecast {
  current: MomentConditions | null;
  hour: MomentConditions | null;
  day: DayConditions | null;
}

/** An instant as WeatherKit's query takes one: ISO 8601, to the second, in UTC. */
const instant = (time: number) => new Date(time).toISOString().replace(/\.\d{3}Z$/, "Z");

/** Asks WeatherKit for a forecast, and reads what it answered. Throws WeatherKitFailure when it
 * can't be asked, doesn't answer, or answers with something other than what was asked for. */
export async function weatherKitForecast(config: WeatherKitConfig, ask: WeatherKitAsk, fetcher: Fetch, now = Date.now()): Promise<WeatherKitForecast> {
  const dataSets = [...(ask.current ? ["currentWeather"] : []), "forecastDaily", ...(ask.at !== null ? ["forecastHourly"] : [])];
  // English: only codes and numbers are read from the answer.
  const url = new URL(`${WEATHERKIT}/api/v1/weather/en/${ask.latitude}/${ask.longitude}`);
  url.searchParams.set("dataSets", dataSets.join(","));
  url.searchParams.set("timezone", ask.timeZone);
  url.searchParams.set("dailyStart", instant(ask.start));
  url.searchParams.set("dailyEnd", instant(ask.end));
  if (ask.at !== null) {
    url.searchParams.set("hourlyStart", instant(ask.start));
    url.searchParams.set("hourlyEnd", instant(ask.end));
  }
  let token: string;
  try {
    token = await weatherKitToken(config, now);
  } catch {
    throw new WeatherKitFailure("couldn't sign with its key");
  }
  let response: Response;
  try {
    response = await fetcher(url.href, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json", "User-Agent": USER_AGENT }, signal: AbortSignal.timeout(10_000) });
  } catch {
    throw new WeatherKitFailure("couldn't be reached");
  }
  if (!response.ok) {
    await response.body?.cancel();
    // A key it doesn't take, or a token it no longer does: signed again next time.
    if (response.status === 401 || response.status === 403) forgetWeatherKitToken();
    throw new WeatherKitFailure(`answered ${response.status}`);
  }
  const body: unknown = await response.json().catch(() => null);
  if (!isObject(body)) throw new WeatherKitFailure("answered with something that isn't a forecast");
  for (const name of dataSets) if (!isObject(body[name])) throw new WeatherKitFailure(`answered without ${name}`);

  const daily = body.forecastDaily as JSONObject;
  const days = Array.isArray(daily.days) ? daily.days.filter(isObject) : [];
  // The day asked for: the one whose span holds the middle of it, which is the first WeatherKit
  // gives for the range, as the phone takes it.
  const middle = (ask.start + ask.end) / 2;
  const day = days.find((one) => Date.parse(String(one.forecastStart)) <= middle && middle < Date.parse(String(one.forecastEnd))) ?? null;
  let hour: MomentConditions | null = null;
  if (ask.at !== null) {
    const hourly = body.forecastHourly as JSONObject;
    const hours = Array.isArray(hourly.hours) ? hourly.hours.filter(isObject) : [];
    let best = Infinity;
    for (const one of hours) {
      const distance = Math.abs(Date.parse(String(one.forecastStart)) - ask.at);
      if (distance < best) {
        best = distance;
        hour = moment(one);
      }
    }
  }
  return { current: ask.current ? moment(body.currentWeather as JSONObject) : null, hour, day: day ? dayOf(day) : null };
}

const number = (value: unknown): number | undefined => (typeof value === "number" && Number.isFinite(value) ? value : undefined);
const percent = (value: unknown): number | undefined => {
  const fraction = number(value);
  return fraction === undefined ? undefined : fraction * 100;
};

/** WeatherCondition's description, from its code: MostlyCloudy is Mostly Cloudy. */
export function conditionOf(code: unknown): string {
  return typeof code === "string" && code ? code.replace(/([a-z])([A-Z])/g, "$1 $2") : "Mixed";
}

/** CurrentWeather and HourWeather as Forecast.reading reads them. WeatherKit's REST API gives
 * temperatures in °C and speeds in km/h, the units the phone converts to, and chances, humidity
 * and cloud cover from 0 to 1, which the phone makes percentages. */
function moment(weather: JSONObject): MomentConditions {
  return {
    temperature: number(weather.temperature),
    feelsLike: number(weather.temperatureApparent),
    rainChance: percent(weather.precipitationChance),
    humidity: percent(weather.humidity),
    windSpeed: number(weather.windSpeed),
    uvIndex: number(weather.uvIndex),
    cloudCover: percent(weather.cloudCover),
    condition: conditionOf(weather.conditionCode),
  };
}

/** DayWeather as Forecast.reading reads it: its high and low, chance of rain, wind (DayWeather's
 * wind is the day's sustained wind, windSpeedAvg; its highWindSpeed is windSpeedMax), highest UV
 * index, and all its precipitation, as liquid, in mm (precipitationAmountByType.precipitation). */
function dayOf(day: JSONObject): DayConditions {
  const daytime = isObject(day.daytimeForecast) ? day.daytimeForecast : {};
  return {
    high: number(day.temperatureMax),
    low: number(day.temperatureMin),
    rainChance: percent(day.precipitationChance),
    windSpeed: number(day.windSpeedAvg) ?? number(daytime.windSpeed),
    uvIndex: number(day.maxUvIndex),
    rainAmount: number(day.precipitationAmount),
    condition: conditionOf(day.conditionCode),
  };
}
