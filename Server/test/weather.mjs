// Checks the weather from Apple Weather (src/compose/weatherkit.ts, through live.ts) in Node, with
// a WeatherKit key made for the test and a stand-in for Apple, so nothing reaches it: the token
// (its shape, its signature checked with the key's public half, and kept for half its hour), what
// WeatherKit is asked for (the place's day where it is, its hours, the weather now), each kind of
// reading's fields against what LiveWeather.swift makes of the same WeatherKit values, Open-Meteo
// standing in when WeatherKit isn't set up or fails, and where the user is: where the phone
// says, then where the network places the request.
//
//   node test/weather.mjs
//
// The source imports without extensions, as the Worker's bundler takes them, so a resolve hook
// finds the .ts file (as test/compose.mjs does).

import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (/^\.\.?\//.test(specifier) && !/\.(ts|mjs|js|json)$/.test(specifier)) {
      try {
        return nextResolve(`${specifier}.ts`, context);
      } catch {
        // Not a TypeScript file.
      }
    }
    return nextResolve(specifier, context);
  },
});

const { SERVICE, conditionOf, forgetWeatherKitToken, weatherKitConfig, weatherKitToken } = await import("../src/compose/weatherkit.ts");
const { APPLE_WEATHER, LiveLog, OPEN_METEO, forgetLiveReadings, hereFor, liveCall, readSource, startOfDay } = await import("../src/compose/live.ts");
const { readComposeRequest } = await import("../src/compose/request.ts");
const { ReferenceLog, ServiceLog, WebLog, toolBox } = await import("../src/compose/tools.ts");
const { Memory } = await import("../src/compose/memory.ts");

const generation = JSON.parse(readFileSync(new URL("../src/generated/generation.json", import.meta.url), "utf8"));

let failures = 0;
function expect(condition, message) {
  console.log(`${condition ? "  ok  " : "  FAIL"}  ${message}`);
  if (!condition) failures++;
}

const KEY_ID = "WKTESTKEY1";
const TEAM_ID = "WKTESTTEAM";
const HOUR = 3_600_000;
/** Thursday 29 October 2026, 11:30 in Bengaluru. */
const NOW = Date.UTC(2026, 9, 29, 6, 0);
const clock = () => NOW;
const IN = { language: "en", region: "IN", currency: "INR", measurementSystem: "metric" };
const US = { language: "en", region: "US", currency: "USD", measurementSystem: "ussystem" };
const iso = (time) => new Date(time).toISOString().replace(/\.\d{3}Z$/, "Z");

/** A WeatherKit key as Apple's .p8 holds one, and its public half. */
async function weatherKitKey() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----`, publicKey: pair.publicKey };
}

/** A token's header and claims, and whether the key's public half verifies it. */
async function readToken(token, publicKey) {
  const [header, claims, signature] = String(token).split(".");
  const verified = !!signature && (await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, Buffer.from(signature, "base64url"), new TextEncoder().encode(`${header}.${claims}`)));
  return { header: JSON.parse(Buffer.from(header, "base64url").toString()), claims: JSON.parse(Buffer.from(claims, "base64url").toString()), verified, signatureBytes: Buffer.from(signature ?? "", "base64url").length };
}

const key = await weatherKitKey();
const config = { key: key.pem, keyID: KEY_ID, teamID: TEAM_ID };

// MARK: - Stand-ins

const META = { attributionURL: "https://developer.apple.com/weatherkit/data-source-attribution/", expireTime: iso(NOW + HOUR), readTime: iso(NOW), reportedTime: iso(NOW - 600_000), units: "m", version: 1 };

/** WeatherKit's values for the stand-in, as its REST API writes them: °C, km/h, mm, and chances,
 * humidity and cloud cover from 0 to 1. */
const CURRENT = { name: "CurrentWeather", metadata: META, asOf: iso(NOW), cloudCover: 0.64, conditionCode: "MostlyCloudy", daylight: true, humidity: 0.78, precipitationIntensity: 0, pressure: 1012.4, pressureTrend: "steady", temperature: 24.6, temperatureApparent: 25.9, temperatureDewPoint: 20.4, uvIndex: 3, visibility: 18000, windDirection: 250, windGust: 21.3, windSpeed: 9.4 };
const dayWeather = (start, end) => ({
  forecastStart: iso(start), forecastEnd: iso(end), conditionCode: "Thunderstorms", maxUvIndex: 8, moonPhase: "waxingGibbous", precipitationAmount: 6.2, precipitationChance: 0.7,
  precipitationType: "rain", snowfallAmount: 0, temperatureMax: 29.4, temperatureMin: 19.1, windGustSpeedMax: 31.5, windSpeedAvg: 11.3, windSpeedMax: 18.9,
  daytimeForecast: { forecastStart: iso(start + 7 * HOUR), forecastEnd: iso(start + 19 * HOUR), cloudCover: 0.55, conditionCode: "Thunderstorms", humidity: 0.66, precipitationAmount: 5.1, precipitationChance: 0.66, precipitationType: "rain", snowfallAmount: 0, windDirection: 240, windSpeed: 12.7 },
});
const hourWeather = (time, index) => ({
  forecastStart: iso(time), cloudCover: 0.2 + index * 0.03, conditionCode: index < 12 ? "PartlyCloudy" : "ScatteredThunderstorms", daylight: index >= 6 && index < 18, humidity: 0.5 + index * 0.01,
  precipitationAmount: 0, precipitationChance: 0.1 + index * 0.02, precipitationType: "clear", pressure: 1010, temperature: 18 + index * 0.6, temperatureApparent: 19 + index * 0.6,
  temperatureDewPoint: 15, uvIndex: Math.max(0, 6 - Math.abs(12 - index)), visibility: 20000, windDirection: 200, windGust: 20, windSpeed: 5 + index * 0.4,
});

/** WeatherKit as it answers: the datasets asked for, the days and hours of the spans asked for. */
const appleAnswers = ({ status = 200, without = [], noDays = false } = {}) => (url) => {
  if (status !== 200) return Response.json({ reason: "NOT_ENABLED" }, { status });
  const sets = (url.searchParams.get("dataSets") ?? "").split(",").filter((set) => !without.includes(set));
  const body = {};
  if (sets.includes("currentWeather")) body.currentWeather = CURRENT;
  if (sets.includes("forecastDaily")) {
    const start = Date.parse(url.searchParams.get("dailyStart"));
    body.forecastDaily = { name: "DailyForecast", metadata: META, days: noDays ? [] : [dayWeather(start, Date.parse(url.searchParams.get("dailyEnd")))] };
  }
  if (sets.includes("forecastHourly")) {
    const hours = [];
    for (let time = Date.parse(url.searchParams.get("hourlyStart")), index = 0; time < Date.parse(url.searchParams.get("hourlyEnd")); time += HOUR, index++) hours.push(hourWeather(time, index));
    body.forecastHourly = { name: "HourlyForecast", metadata: META, hours };
  }
  return Response.json(body);
};

const PLACES = {
  "new york": { name: "New York", latitude: 40.71427, longitude: -74.00597, timezone: "America/New_York", country: "United States" },
  mysuru: { name: "Mysuru", latitude: 12.29791, longitude: 76.63925, timezone: "Asia/Kolkata", country: "India", admin1: "Karnataka" },
};

/** Open-Meteo as it answers, as test/compose.mjs has it. */
function openMeteo(url) {
  const day = url.searchParams.get("start_date");
  const hours = Array.from({ length: 24 }, (_, hour) => `${day}T${String(hour).padStart(2, "0")}:00`);
  const rising = (from) => hours.map((_, hour) => from + hour);
  return Response.json({
    timezone: url.searchParams.get("timezone"),
    current: { time: `${day}T09:15`, temperature_2m: 24.1, apparent_temperature: 25.2, relative_humidity_2m: 74, wind_speed_10m: 8.8, uv_index: 3.4, cloud_cover: 60, weather_code: 3 },
    hourly: { time: hours, temperature_2m: rising(18), apparent_temperature: rising(19), precipitation_probability: rising(10), relative_humidity_2m: rising(50), wind_speed_10m: rising(5), uv_index: hours.map((_, hour) => hour / 2), cloud_cover: rising(20), weather_code: hours.map(() => 61) },
    daily: { time: [day], temperature_2m_max: [28.8], temperature_2m_min: [19.6], precipitation_probability_max: [65], precipitation_sum: [5.5], wind_speed_10m_max: [14.8], uv_index_max: [7.6], weather_code: [61] },
  });
}

/** The network, standing in: WeatherKit as `apple` answers, and Open-Meteo's geocoding and
 * forecast. Each request is kept, with its headers. */
function network(apple = appleAnswers()) {
  const asked = [];
  const fetcher = async (address, init = {}) => {
    const url = new URL(String(address));
    asked.push({ url, headers: init.headers ?? {} });
    if (url.host === "weatherkit.apple.com") return apple(url, init);
    if (url.host === "geocoding-api.open-meteo.com") {
      const found = PLACES[url.searchParams.get("name").toLowerCase()];
      return Response.json(found ? { results: [found] } : { generationtime_ms: 0.2 });
    }
    if (url.host === "api.open-meteo.com") return openMeteo(url);
    throw new Error(`No stand-in for ${address}`);
  };
  fetcher.apple = () => asked.filter((one) => one.url.host === "weatherkit.apple.com");
  fetcher.meteo = () => asked.filter((one) => one.url.host === "api.open-meteo.com");
  fetcher.asked = asked;
  return fetcher;
}

const liveArgs = (fields) => ({ name: "", kind: "weather", place: "", day: "", time: "", from: "", to: "", travel: "", ...fields });

/** One live tool call, as the loop makes it. */
async function live(fields, { fetcher = network(), weatherKit = config, here = null, reader = IN } = {}) {
  const notes = [];
  const log = new LiveLog();
  const context = { fetch: fetcher, now: clock, here, reader, weatherKit };
  const output = await liveCall(generation, liveArgs(fields), log, context, (line) => notes.push(line));
  return { output, sources: log.sources, notes, fetcher, context };
}

/** What the Worker's log hears while `work` runs. */
async function logged(work) {
  const lines = [];
  const { log, warn } = console;
  console.log = (...parts) => lines.push(parts.join(" "));
  console.warn = (...parts) => lines.push(parts.join(" "));
  try {
    return { result: await work(), lines };
  } finally {
    console.log = log;
    console.warn = warn;
  }
}

/** LiveWeather.swift's Forecast.reading, line for line, over the stand-in's WeatherKit values:
 * what the phone makes of the same forecast. The phone converts temperatures to °C and speeds to
 * km/h, which WeatherKit's REST API already gives, and multiplies chances, humidity and cloud cover
 * by 100. Its DayWeather.wind is the day's sustained wind, windSpeedAvg. */
function phoneFields({ current = null, hour = null, day, isToday, moment }) {
  const fields = [];
  const add = (name, value, unit, format, meaning) => {
    if (Number.isFinite(value)) fields.push({ name, value, unit, format, meaning });
  };
  add("high", day.temperatureMax, "°C", "number", "the day's highest temperature");
  add("low", day.temperatureMin, "°C", "number", "the day's lowest temperature");
  if (hour) {
    add("temperature", hour.temperature, "°C", "number", `the temperature ${moment}`);
    add("feelsLike", hour.temperatureApparent, "°C", "number", `what it feels like ${moment}`);
    add("rainChance", hour.precipitationChance * 100, "", "percent", `the chance of rain ${moment}`);
    add("humidity", hour.humidity * 100, "", "percent", `humidity ${moment}`);
    add("windSpeed", hour.windSpeed, "km/h", "number", `wind speed ${moment}`);
    add("uvIndex", hour.uvIndex, "", "integer", `the UV index ${moment}`);
    add("cloudCover", hour.cloudCover * 100, "", "percent", `cloud cover ${moment}`);
  } else if (isToday) {
    add("temperature", current.temperature, "°C", "number", "the temperature now");
    add("feelsLike", current.temperatureApparent, "°C", "number", "what it feels like now");
    add("rainChance", day.precipitationChance * 100, "", "percent", "the chance of rain today");
    add("humidity", current.humidity * 100, "", "percent", "humidity now");
    add("windSpeed", current.windSpeed, "km/h", "number", "wind speed now");
    add("uvIndex", current.uvIndex, "", "integer", "the UV index now");
    add("cloudCover", current.cloudCover * 100, "", "percent", "cloud cover now");
  } else {
    add("rainChance", day.precipitationChance * 100, "", "percent", "the chance of rain during the day");
    add("windSpeed", day.windSpeedAvg, "km/h", "number", "wind speed during the day");
    add("uvIndex", day.maxUvIndex, "", "integer", "the day's highest UV index");
  }
  add("rainAmount", day.precipitationAmount, "mm", "number", "how much rain is expected during the day");
  return fields;
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
/** A day in Bengaluru, from its midnight to the next. */
const kolkataDay = (date) => [Date.UTC(...date) - 5.5 * HOUR, Date.UTC(...date) + 18.5 * HOUR];
const PHONE = { latitude: 12.97, longitude: 77.59, name: "Bengaluru, Karnataka, India", timeZone: "Asia/Kolkata" };
const MUMBAI = { latitude: 19.07, longitude: 72.88, city: "Mumbai", timeZone: "Asia/Kolkata" };

// MARK: - The token

console.log("WeatherKit's token");
{
  expect(weatherKitConfig({}) === null && weatherKitConfig({ WEATHERKIT_KEY: key.pem, WEATHERKIT_KEY_ID: KEY_ID }) === null && weatherKitConfig({ WEATHERKIT_KEY: key.pem, WEATHERKIT_KEY_ID: " ", WEATHERKIT_TEAM_ID: TEAM_ID }) === null, "off until all three secrets are set");
  expect(same(weatherKitConfig({ WEATHERKIT_KEY: key.pem, WEATHERKIT_KEY_ID: ` ${KEY_ID}\n`, WEATHERKIT_TEAM_ID: TEAM_ID }), config), "and read as they're pasted");

  forgetWeatherKitToken();
  const token = await weatherKitToken(config, NOW);
  const read = await readToken(token, key.publicKey);
  expect(same(read.header, { alg: "ES256", kid: KEY_ID, id: `${TEAM_ID}.xyz.onlychan.Dream` }) && SERVICE === "xyz.onlychan.Dream", "its header: ES256, the key's ID, and the team and the app's bundle ID");
  expect(same(read.claims, { iss: TEAM_ID, iat: NOW / 1000, exp: NOW / 1000 + 3600, sub: "xyz.onlychan.Dream" }), "its claims: the team, when it was made, an hour later, and the app");
  expect(read.verified && read.signatureBytes === 64, "signed with the key, as r ‖ s, which its public half verifies");
  expect((await weatherKitToken(config, NOW + 29 * 60_000)) === token, "reused for half an hour");
  const later = await weatherKitToken(config, NOW + 31 * 60_000);
  expect(later !== token && (await readToken(later, key.publicKey)).claims.iat === NOW / 1000 + 31 * 60, "then made again, well before the first runs out");
  expect((await weatherKitToken({ ...config, keyID: "ANOTHERKEY" }, NOW + 31 * 60_000)) !== later, "and made again for another key");
}

// MARK: - The weather, as the phone reads it

console.log("Apple Weather: today, where the phone says the user is");
{
  forgetLiveReadings();
  forgetWeatherKitToken();
  const here = hereFor(PHONE, MUMBAI);
  expect(same(here, { latitude: 12.97, longitude: 77.59, city: "Bengaluru", timeZone: "Asia/Kolkata", from: "phone" }), "the phone's place comes first, called by its town, with the phone's time zone");
  const now = await live({ name: "now", place: "here" }, { here });
  const apple = now.fetcher.apple();
  const url = apple[0]?.url;
  const [start, end] = kolkataDay([2026, 9, 29]);
  expect(apple.length === 1 && url.pathname === "/api/v1/weather/en/12.97/77.59" && now.fetcher.meteo().length === 0 && !now.fetcher.asked.some((one) => one.url.host.includes("geocoding")), "WeatherKit is asked for where the phone is, not where the network says, and nothing else is");
  expect(url.searchParams.get("dataSets") === "currentWeather,forecastDaily" && url.searchParams.get("timezone") === "Asia/Kolkata" && url.searchParams.get("dailyStart") === iso(start) && url.searchParams.get("dailyEnd") === iso(end) && !url.searchParams.has("hourlyStart"), "for the weather now and the day, from Bengaluru's midnight to the next, rolled up in its time zone");
  const bearer = String(apple[0].headers.Authorization ?? "");
  const token = await readToken(bearer.replace(/^Bearer /, ""), key.publicKey);
  expect(bearer.startsWith("Bearer ") && token.verified && token.claims.sub === SERVICE, "with the token, as a bearer");
  const day = dayWeather(start, end);
  expect(same(now.sources, [{ name: "now", kind: "weather", parameters: { place: "current location" }, fields: phoneFields({ current: CURRENT, day, isToday: true }) }]), "today: the fields LiveWeather.swift makes from the same WeatherKit values, and the page says current location, never where");
  expect(now.output.startsWith("Live source now: Bengaluru, now and today: Mostly Cloudy\n- now.high = 29.4 °C: the day's highest temperature\n") && now.output.includes("\n- now.humidity = 78%: humidity now\n"), "what the model reads: the town and WeatherKit's condition, as WeatherCondition describes it");
  expect(!`${now.output}${JSON.stringify(now.sources)}${now.notes.join()}`.includes("12.97") && !now.output.includes("Karnataka"), "and nothing of where, beyond the town");
  expect(same(now.notes, ["Live: now, weather (place current location)", "Weather from Apple Weather, where the phone is"]), "the log says it was Apple Weather's, for where the phone is");
  const reading = await readSource(now.sources[0], now.context);
  expect(same(reading.credit, APPLE_WEATHER) && APPLE_WEATHER.kind === "appleWeather" && APPLE_WEATHER.legal === "https://weatherkit.apple.com/legal-attribution.html", "credited as the phone credits it: the Apple Weather mark and its legal page");
  expect(now.fetcher.apple().length === 1, "and read again moments later, it's the reading kept");
}

console.log("Apple Weather: another day, and an hour of one");
{
  forgetLiveReadings();
  const tomorrow = await live({ name: "weather", place: "Mysuru", day: "tomorrow" });
  const url = tomorrow.fetcher.apple()[0].url;
  const [start, end] = kolkataDay([2026, 9, 30]);
  expect(url.pathname === "/api/v1/weather/en/12.29791/76.63925" && url.searchParams.get("dataSets") === "forecastDaily" && url.searchParams.get("dailyStart") === iso(start) && url.searchParams.get("dailyEnd") === iso(end), "a place by name: where Open-Meteo's geocoding finds it, and only its day, tomorrow there");
  expect(same(tomorrow.sources[0].fields, phoneFields({ day: dayWeather(start, end), isToday: false })), "another day: the high and low, chance of rain, the day's wind, highest UV index and rain, as the phone has them");
  expect(tomorrow.output.startsWith("Live source weather: Mysuru, ") && tomorrow.output.includes(": Thunderstorms\n") && same(tomorrow.notes, ["Live: weather, weather (day tomorrow, place Mysuru)", "Weather from Apple Weather"]), "said for the model, and logged");

  const picnic = await live({ name: "picnic", place: "Mysuru", day: "saturday", time: "16:00" }, { reader: US });
  const asked = picnic.fetcher.apple()[0].url;
  const [saturday, sunday] = kolkataDay([2026, 9, 31]);
  expect(asked.searchParams.get("dataSets") === "forecastDaily,forecastHourly" && asked.searchParams.get("hourlyStart") === iso(saturday) && asked.searchParams.get("hourlyEnd") === iso(sunday), "an hour: the day's hours too, the coming Saturday's");
  const at = `at ${new Intl.DateTimeFormat("en-US", { timeZone: "UTC", hour: "numeric", minute: "2-digit" }).format(Date.UTC(2026, 0, 1, 16))}`;
  expect(same(picnic.sources[0].fields, phoneFields({ hour: hourWeather(saturday + 16 * HOUR, 16), day: dayWeather(saturday, sunday), isToday: false, moment: at })), "at an hour: the hour nearest 16:00 where the place is, as the phone has it");
  expect(picnic.output.includes(": Scattered Thunderstorms\n") && picnic.output.includes("- picnic.high = 84.92 °F: the day's highest temperature"), "with that hour's condition, and said in the reader's units, though the page keeps °C");

  const evening = await live({ name: "evening", place: "Mysuru", day: "today", time: "6 pm" });
  const tonight = evening.fetcher.apple()[0].url;
  expect(tonight.searchParams.get("dataSets") === "currentWeather,forecastDaily,forecastHourly" && evening.sources[0].fields.find((field) => field.name === "temperature")?.value === hourWeather(0, 18).temperature, "an hour today: the weather now too, as the phone asks, but the hour's values");
}

console.log("Apple Weather: days where the clocks change");
{
  expect(startOfDay(Date.UTC(2026, 9, 29), "Asia/Kolkata") === Date.UTC(2026, 9, 28, 18, 30) && startOfDay(Date.UTC(2026, 9, 29), "UTC") === Date.UTC(2026, 9, 29), "a day starts at its midnight where the place is");
  forgetLiveReadings();
  const sunday = await live({ name: "nyc", place: "New York", day: "2026-11-01" });
  const url = sunday.fetcher.apple()[0].url;
  expect(url.searchParams.get("timezone") === "America/New_York" && url.searchParams.get("dailyStart") === "2026-11-01T04:00:00Z" && url.searchParams.get("dailyEnd") === "2026-11-02T05:00:00Z", "the day New York's clocks go back is 25 hours long, from midnight to midnight there");
  expect(conditionOf("BlowingDust") === "Blowing Dust" && conditionOf("Clear") === "Clear" && conditionOf(undefined) === "Mixed", "WeatherKit's codes read as WeatherCondition describes them");
}

console.log("Apple Weather: when it has no forecast for the day");
{
  forgetLiveReadings();
  const empty = await live({ name: "w", place: "Mysuru", day: "today" }, { fetcher: network(appleAnswers({ noDays: true })) });
  expect(empty.output === "There's no forecast for that day yet. Don't show these values, and don't make them up." && empty.sources.length === 0 && empty.fetcher.meteo().length === 0, "the model is told, in the phone's words, and Open-Meteo isn't asked instead");
}

// MARK: - Open-Meteo, standing in

console.log("Open-Meteo, when Apple Weather isn't set up or fails");
{
  forgetLiveReadings();
  const { result: unset, lines } = await logged(async () => [await live({ name: "a", place: "Mysuru", day: "today" }, { weatherKit: null }), await live({ name: "b", place: "Mysuru", day: "tomorrow" }, { weatherKit: null })]);
  expect(unset.every((one) => one.fetcher.apple().length === 0 && one.fetcher.meteo().length === 1), "without its secrets, WeatherKit isn't asked, and Open-Meteo is");
  expect(same(unset[0].sources[0].fields.map((field) => field.name), ["high", "low", "temperature", "feelsLike", "rainChance", "humidity", "windSpeed", "uvIndex", "cloudCover", "rainAmount"]) && unset[0].sources[0].fields[0].value === 28.8 && unset[0].sources[0].fields.find((field) => field.name === "rainChance").value === 65, "with the same fields, made the same way");
  expect(unset[0].notes[1] === "Weather from Open-Meteo, since Apple Weather isn't set up" && same(lines, ["The weather is from Open-Meteo: WEATHERKIT_KEY, WEATHERKIT_KEY_ID and WEATHERKIT_TEAM_ID aren't set."]), "the page's log says so each time, and the Worker's once");
  expect(same((await readSource(unset[0].sources[0], unset[0].context)).credit, OPEN_METEO), "credited to Open-Meteo, as its licence asks");

  const failing = [
    [appleAnswers({ status: 500 }), "answered 500"],
    [appleAnswers({ without: ["forecastDaily"] }), "answered without forecastDaily"],
    [() => Response.json(["not", "a", "forecast"]), "answered with something that isn't a forecast"],
    [() => Promise.reject(new TypeError("Network connection lost.")), "couldn't be reached"],
  ];
  for (const [apple, why] of failing) {
    forgetLiveReadings();
    const { result, lines } = await logged(() => live({ name: "w", place: "Mysuru", day: "tomorrow" }, { fetcher: network(apple) }));
    expect(result.fetcher.apple().length === 1 && result.fetcher.meteo().length === 1 && result.sources[0]?.fields.length === 6 && result.notes[1] === `Weather from Open-Meteo, since Apple Weather ${why}` && same(lines, [`The weather is from Open-Meteo: Apple Weather ${why}.`]), `when Apple Weather ${why}, Open-Meteo's, and both logs say why`);
  }
  forgetLiveReadings();
  forgetWeatherKitToken();
  const { result: unsigned } = await logged(() => live({ name: "w", place: "Mysuru", day: "today" }, { weatherKit: { ...config, key: "not a key" } }));
  expect(unsigned.fetcher.apple().length === 0 && unsigned.notes[1] === "Weather from Open-Meteo, since Apple Weather couldn't sign with its key", "and when the key can't sign, it isn't asked at all");
}

console.log("Apple Weather: a token it refuses is made again");
{
  forgetLiveReadings();
  forgetWeatherKitToken();
  let refuse = true;
  const answer = appleAnswers();
  const fetcher = network((url) => (refuse ? Response.json({ reason: "NOT_ENABLED" }, { status: 401 }) : answer(url)));
  const { result: refused } = await logged(() => live({ name: "a", place: "Mysuru", day: "today" }, { fetcher }));
  refuse = false;
  await live({ name: "b", place: "Mysuru", day: "tomorrow" }, { fetcher });
  await live({ name: "c", place: "Mysuru", day: "saturday" }, { fetcher });
  const tokens = fetcher.apple().map((one) => one.headers.Authorization);
  expect(refused.notes[1] === "Weather from Open-Meteo, since Apple Weather answered 401" && tokens.length === 3 && tokens[1] !== tokens[0] && tokens[2] === tokens[1], "after a 401 the next request signs a new token, which is then reused");
}

// MARK: - Where the user is

console.log("Where the user is: the phone's, then the network's");
{
  expect(same(hereFor(undefined, MUMBAI), { ...MUMBAI, from: "network" }) && hereFor(undefined, null) === null, "without the phone's, where the network places the request, or nowhere");
  expect(same(hereFor({ latitude: 12.97, longitude: 77.59, name: "" }, MUMBAI), { latitude: 12.97, longitude: 77.59, timeZone: "Asia/Kolkata", from: "phone" }) && hereFor({ latitude: 1, longitude: 2, name: "Somewhere" }, null).timeZone === undefined, "a place the phone couldn't name, and a time zone it didn't send: the network's, or none");
  forgetLiveReadings();
  const network_ = await live({ name: "now", place: "current location" }, { here: hereFor(undefined, MUMBAI) });
  expect(network_.fetcher.apple()[0].url.pathname === "/api/v1/weather/en/19.07/72.88" && network_.output.startsWith("Live source now: Mumbai, now and today") && network_.notes[1] === "Weather from Apple Weather, where the request came from", "the weather here is where the network says, when the phone doesn't say");
  const unnamed = await live({ name: "now", place: "me" }, { here: hereFor({ latitude: 12.97, longitude: 77.59, name: "", timeZone: "Asia/Kolkata" }, null) });
  expect(unnamed.output.startsWith("Live source now: your location, now and today"), "a place without a name is your location");
  const nowhere = await live({ name: "now", place: "current location" });
  expect(nowhere.output === "Dream couldn't find where you are. Don't show these values, and don't make them up." && nowhere.fetcher.apple().length === 0, "and with neither, the model is told so, as before");

  const sent = { request: "will it rain here today?", locale: IN, pageID: "6F9619FF-8B86-D011-B42D-00C04FC964FF" };
  const read = readComposeRequest({ ...sent, here: { latitude: 12.971599, longitude: 77.594566, name: "  Bengaluru,  Karnataka, India ", timeZone: "Asia/Kolkata" } });
  expect(same(read.request?.here, { latitude: 12.97, longitude: 77.59, name: "Bengaluru, Karnataka, India", timeZone: "Asia/Kolkata" }), "the request's here: to about a kilometre whatever's sent, its name tidied, the phone's time zone");
  expect(readComposeRequest({ ...sent, here: { ...PHONE, timeZone: "../etc" } }).request?.here.timeZone === undefined && !("here" in readComposeRequest(sent).request) && !("here" in readComposeRequest({ ...sent, here: null }).request), "a time zone that isn't one is left out, and without here there's none");
  const refused = [{ latitude: 100, longitude: 0, name: "x" }, { latitude: "12.97", longitude: 77.59, name: "x" }, { latitude: 12.97, longitude: 77.59 }, { latitude: 12.97, longitude: 77.59, name: "x".repeat(201) }, "Bengaluru"];
  expect(refused.every((here) => "error" in readComposeRequest({ ...sent, here })), "and one that isn't a place on Earth with a name is refused");
}

console.log("The live tool on a page: Apple Weather through the page's tools");
{
  forgetLiveReadings();
  const fetcher = network();
  const services = { lookup: async () => null, related: async () => [], search: async () => ({ status: 503, body: {} }), read: async () => ({ status: 503, body: {} }), memory: async () => [], fetch: fetcher, here: hereFor(PHONE, null), weatherKit: config };
  const session = { found: new ReferenceLog(), web: new WebLog(), live: new LiveLog(), memory: new Memory(async () => []), services: new ServiceLog(), language: "en", reader: IN, device: null, now: clock };
  const box = toolBox(generation, services, { trace() {}, use() {}, note() {} }, session);
  const said = await box.run("live", JSON.stringify(liveArgs({ name: "now", place: "here" })));
  expect(said.startsWith("Live source now: Bengaluru, now and today: Mostly Cloudy") && fetcher.apple().length === 1 && session.live.sources[0].parameters.place === "current location", "the job's WeatherKit and where the user is reach the live tool");
}

console.log(failures ? `\n${failures} failed` : "\nAll passed");
process.exit(failures ? 1 : 0);
