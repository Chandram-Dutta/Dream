// What POST /api/compose takes (contract.ts), checked before a job is made for it: the request
// and its photo within the sizes the app sends, the locale's fields, the context lines, an id
// the app's sync can keep the page under, a change to a page, the phone's own tools, and where
// the user is.
//
// Only types are imported, so test/compose.mjs runs it in Node.

import type { ComposeEditing, ComposeRequest, DeviceToolDefinition } from "./contract";

type JSONObject = Record<string, unknown>;

const isObject = (value: unknown): value is JSONObject => value !== null && typeof value === "object" && !Array.isArray(value);

/** As /api/route takes a request. */
export const MAX_REQUEST = 4_000;
/** A JPEG at most 1024 pixels on its longer side is well under a megabyte. */
export const MAX_IMAGE = 1_500_000;
const MAX_CONTEXT_LINES = 40;
const MAX_CONTEXT = 20_000;
const EFFORTS = new Set(["none", "low", "medium", "high", "max"]);
/** The app's page ids are UUIDs (SavedSurface.id), which it reads sync items' ids back as. */
const PAGE_ID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

/** The request, checked and tidied, or what's wrong with it. */
export function readComposeRequest(body: unknown): { request: ComposeRequest } | { error: string } {
  if (!isObject(body)) return { error: "Expected a JSON object." };
  const text = typeof body.request === "string" ? body.request.trim() : "";
  if (!text || text.length > MAX_REQUEST) return { error: `Send the request, up to ${MAX_REQUEST.toLocaleString("en")} characters.` };

  let image: string | undefined;
  if (body.image !== undefined && body.image !== null && body.image !== "") {
    if (typeof body.image !== "string") return { error: "image is a JPEG, as base64." };
    const raw = body.image.replace(/^data:image\/jpeg;base64,/, "");
    if (raw.length > MAX_IMAGE) return { error: "That photo is too big. Send one at most 1024 pixels on its longer side." };
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(raw) || !raw.startsWith("/9j/")) return { error: "image is a JPEG, as base64." };
    image = raw;
  }

  const model = body.model === undefined || body.model === null || body.model === "" ? undefined : body.model;
  if (model !== undefined && !(typeof model === "string" && /^[A-Za-z0-9._-]{1,64}$/.test(model))) return { error: "model is auto, or a model's id." };
  const thinking = body.thinking === undefined || body.thinking === null || body.thinking === "" ? undefined : body.thinking;
  if (thinking !== undefined && !(typeof thinking === "string" && EFFORTS.has(thinking))) return { error: "thinking is none, low, medium, high or max." };

  const locale = body.locale;
  if (!isObject(locale)) return { error: "Send the locale: language, region, currency and measurementSystem." };
  const field = (name: string, pattern: RegExp) => (typeof locale[name] === "string" && pattern.test(locale[name] as string) ? (locale[name] as string) : null);
  const language = field("language", /^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8}){0,3}$/);
  const region = field("region", /^[A-Za-z0-9]{0,3}$/);
  const currency = field("currency", /^[A-Za-z]{3}$/);
  const measurementSystem = field("measurementSystem", /^[A-Za-z]{1,20}$/);
  if (language === null || region === null || currency === null || measurementSystem === null) return { error: "Send the locale: language, region, currency and measurementSystem." };

  let context: string[] | undefined;
  if (body.context !== undefined && body.context !== null) {
    if (!Array.isArray(body.context) || body.context.length > MAX_CONTEXT_LINES || !body.context.every((line) => typeof line === "string")) {
      return { error: `context is a list of up to ${MAX_CONTEXT_LINES} lines.` };
    }
    if ((body.context as string[]).reduce((total, line) => total + line.length, 0) > MAX_CONTEXT) return { error: "That's too much context at once." };
    context = (body.context as string[]).filter((line) => line.trim());
  }

  if (typeof body.pageID !== "string" || !PAGE_ID.test(body.pageID)) return { error: "pageID is the id the page is kept under: a UUID." };

  let editing: ComposeEditing | undefined;
  if (body.editing !== undefined && body.editing !== null) {
    const checked = readEditing(body.editing);
    if ("error" in checked) return checked;
    editing = checked.editing;
  }

  let deviceTools: DeviceToolDefinition[] | undefined;
  if (body.deviceTools !== undefined && body.deviceTools !== null) {
    const checked = readDeviceTools(body.deviceTools);
    if ("error" in checked) return checked;
    if (checked.tools.length) deviceTools = checked.tools;
  }

  let here: ComposeRequest["here"];
  if (body.here !== undefined && body.here !== null) {
    const checked = readHere(body.here);
    if ("error" in checked) return checked;
    here = checked.here;
  }

  return {
    request: {
      request: text,
      ...(image ? { image } : {}),
      ...(model ? { model } : {}),
      ...(thinking ? { thinking } : {}),
      locale: { language: language.replace(/_/g, "-"), region, currency: currency.toUpperCase(), measurementSystem },
      ...(context ? { context } : {}),
      pageID: body.pageID,
      ...(editing ? { editing } : {}),
      ...(deviceTools ? { deviceTools } : {}),
      ...(here ? { here } : {}),
    },
  };
}

/** Where the user is: a place on Earth, to about a kilometre whatever was sent, and its name. */
function readHere(value: unknown): { here: NonNullable<ComposeRequest["here"]> } | { error: string } {
  const wrong = { error: "here is where the user is: latitude, longitude and the place's name." };
  if (!isObject(value) || typeof value.latitude !== "number" || typeof value.longitude !== "number" || typeof value.name !== "string") return wrong;
  if (!(Math.abs(value.latitude) <= 90 && Math.abs(value.longitude) <= 180)) return wrong;
  const name = value.name.replace(/\s+/g, " ").trim();
  if (name.length > 200) return wrong;
  // A time zone's name, like America/Argentina/Buenos_Aires; one that isn't is left out.
  const timeZone = typeof value.timeZone === "string" && /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+){0,2}$/.test(value.timeZone) && value.timeZone.length <= 64 ? value.timeZone : undefined;
  const coarse = (degrees: number) => Math.round(degrees * 100) / 100;
  return { here: { latitude: coarse(value.latitude), longitude: coarse(value.longitude), name, ...(timeZone ? { timeZone } : {}) } };
}

/** A page as big as sync keeps one (Sync.maxItem), which is what's being changed. */
export const MAX_SURFACE = 250_000;
const MAX_INSTRUCTION = 4_000;
const MAX_DEVICE_TOOLS = 40;
const MAX_DEVICE_TOOLS_BYTES = 200_000;
/** How the model calls a tool, as chat completions allow function names. */
const TOOL_NAME = /^[A-Za-z0-9_-]{1,64}$/;

const bytes = (value: unknown) => new TextEncoder().encode(JSON.stringify(value)).length;

/** A change to a page: the page as it is, and one of an instruction, a different answer, or
 * made again. */
function readEditing(value: unknown): { editing: ComposeEditing } | { error: string } {
  if (!isObject(value)) return { error: "editing is the page and what to change about it." };
  const surface = value.surface;
  if (!isObject(surface) || typeof surface.title !== "string" || !Array.isArray(surface.blocks)) return { error: "editing.surface is the page, as the app's Surface encodes it." };
  if (bytes(surface) > MAX_SURFACE) return { error: "That page is too big to change here." };
  const instruction = typeof value.instruction === "string" ? value.instruction.trim() : "";
  const again = value.again === true;
  const answer = value.answer;
  const asked = [instruction !== "", again, answer !== undefined && answer !== null].filter(Boolean).length;
  if (asked !== 1) return { error: "editing has one of instruction, answer or again." };
  if (instruction) {
    if (instruction.length > MAX_INSTRUCTION) return { error: `Say what to change in up to ${MAX_INSTRUCTION.toLocaleString("en")} characters.` };
    const focus = typeof value.focus === "string" && value.focus.trim() ? value.focus.trim() : undefined;
    if (focus !== undefined && focus.length > 200) return { error: "focus is the id of the block they pointed at." };
    return { editing: { surface, instruction, ...(focus ? { focus } : {}) } };
  }
  if (again) return { editing: { surface, again: true } };
  if (!isObject(answer) || !isObject(answer.question) || typeof answer.question.text !== "string" || typeof answer.choice !== "string" || answer.choice.length > 300) {
    return { error: "editing.answer is the question, as the page's answers hold it, and the new choice." };
  }
  return { editing: { surface, answer: { question: answer.question, choice: answer.choice.trim() } } };
}

/** The phone's tools: each with a name the model can call, what it does, and its arguments. */
function readDeviceTools(value: unknown): { tools: DeviceToolDefinition[] } | { error: string } {
  if (!Array.isArray(value) || value.length > MAX_DEVICE_TOOLS || bytes(value) > MAX_DEVICE_TOOLS_BYTES) return { error: `deviceTools is a list of up to ${MAX_DEVICE_TOOLS} tools.` };
  const tools: DeviceToolDefinition[] = [];
  for (const tool of value) {
    if (!isObject(tool) || typeof tool.name !== "string" || !TOOL_NAME.test(tool.name) || typeof tool.description !== "string" || tool.description.length > 4_000 || !isObject(tool.parameters)) {
      return { error: "Each of deviceTools has a name (letters, digits, _ and -), a description and parameters as a JSON Schema object." };
    }
    if (tools.some((other) => other.name === tool.name)) return { error: `deviceTools has ${tool.name} twice.` };
    const service = typeof tool.service === "string" && tool.service.trim() ? tool.service.trim().slice(0, 100) : undefined;
    tools.push({ name: tool.name, description: tool.description, parameters: tool.parameters, ...(service ? { service } : {}) });
  }
  return { tools };
}
