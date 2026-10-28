// What POST /api/compose takes (contract.ts), checked before a job is made for it: the request
// and its photo within the sizes the app sends, the locale's fields, the context lines, and an id
// the app's sync can keep the page under.
//
// No imports, so test/unit.mjs runs it in Node.

import type { ComposeRequest } from "./contract";

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

  return {
    request: {
      request: text,
      ...(image ? { image } : {}),
      ...(model ? { model } : {}),
      ...(thinking ? { thinking } : {}),
      locale: { language: language.replace(/_/g, "-"), region, currency: currency.toUpperCase(), measurementSystem },
      ...(context ? { context } : {}),
      pageID: body.pageID,
    },
  };
}
