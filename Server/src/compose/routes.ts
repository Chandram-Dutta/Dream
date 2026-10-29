// Pages made on the server (docs/ServerGeneration.md): the routes the app starts, watches and
// answers a page through. Each page is a PageJob (job.ts), which keeps going whether or not
// anyone watches.
//
//   POST /api/compose                     a ComposeRequest (contract.ts), from the app → { id }
//   GET  /api/compose/:id/events?after=   the job's events since a seq, as server-sent events
//   POST /api/compose/:id/answers         { answers }: the answers to its questions
//   POST /api/compose/:id/tools           { id, output }: what one of the phone's tools returned
//
// Starting a page is like asking /api/model: the user's session, proof that it's the app
// (attest.ts), and the account's allowance, which counts the page then. Watching and answering
// need the session of the account the page is for, and nobody else's. Where the user is goes
// with the page, for the weather "here": where the phone says, when they've let it (the
// request's `here`), or else where Cloudflare places the request. Its coordinates are never kept
// on the page, which says "current location", nor told to the model.

import { countsAllowed } from "../analytics";
import { proveApp } from "../attest";
import { signInNeeded, userFrom } from "../auth";
import { allowed, bodyBytes, isJSON, json, object, problem } from "../reply";
import { accountOf, admitModel, refusalResponse } from "../usage";
import type { ComposeStarted } from "./contract";
import type { ComposeEnv } from "./job";
import { hereFor, type Here } from "./live";
import { readComposeRequest } from "./request";

/** A page's request is a few KB, with a photo up to about 1.5 MB more as base64. */
const MAX_BODY = 2_000_000;
const MAX_ANSWERS = 50_000;
/** A tool's answer: a connected service's is cut to 8,000 characters on the phone, and a live
 * source rides along. */
const MAX_TOOL_OUTPUT = 200_000;
/** A job's id, as Durable Objects write theirs. */
const JOB_ID = /^[0-9a-f]{64}$/;

const only = (method: string) => problem(405, `Only ${method}.`, { Allow: method });

/** The routes here, or null for any other path. */
export async function routeCompose(request: Request, env: ComposeEnv, url: URL): Promise<Response | null> {
  if (url.pathname === "/api/compose") return request.method === "POST" ? start(request, env, url) : only("POST");
  const match = /^\/api\/compose\/([^/]+)\/(events|answers|tools)$/.exec(url.pathname);
  if (!match) return null;
  const [, id, what] = match;
  if (what === "events" && request.method !== "GET") return only("GET");
  if (what !== "events" && request.method !== "POST") return only("POST");
  const user = await userFrom(request, env);
  if (!user) return signInNeeded();
  if (!(await allowed(env.MODEL_LIMIT, `compose-${what}:${user.id}`))) return problem(429, "Too many requests at once. Try again in a minute.", { "Retry-After": "60" });
  const job = jobFor(env, id);
  if (!job) return problem(404, "There's no page being made with that id.");
  if (what === "events") {
    const after = url.searchParams.get("after") ?? "0";
    if (!/^\d{1,15}$/.test(after)) return problem(400, "after is the last seq you saw, or 0.");
    return job.fetch(`https://page-job/events?after=${after}`, { headers: { "X-Dream-User": user.id } });
  }
  if (!isJSON(request)) return problem(415, "Send application/json.");
  const raw = await bodyBytes(request, what === "tools" ? MAX_TOOL_OUTPUT : MAX_ANSWERS);
  if (!raw) return problem(413, "That's too much to send at once.");
  const body = object(raw);
  if (!body) return problem(400, "Expected a JSON object.");
  return job.fetch(`https://page-job/${what}`, { method: "POST", headers: { "Content-Type": "application/json", "X-Dream-User": user.id }, body: JSON.stringify(body) });
}

/** Where the request came from, as Cloudflare places it, or null when it doesn't. */
function hereOf(request: Request): Here | null {
  const cf = (request as { cf?: Record<string, unknown> }).cf;
  const latitude = Number(cf?.latitude);
  const longitude = Number(cf?.longitude);
  if (!cf || typeof cf.latitude !== "string" || !Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
  return {
    latitude,
    longitude,
    ...(typeof cf.city === "string" && cf.city ? { city: cf.city } : {}),
    ...(typeof cf.timezone === "string" && cf.timezone ? { timeZone: cf.timezone } : {}),
  };
}

function jobFor(env: ComposeEnv, id: string): DurableObjectStub | null {
  if (!env.PAGE_JOBS || !JOB_ID.test(id)) return null;
  try {
    return env.PAGE_JOBS.get(env.PAGE_JOBS.idFromString(id));
  } catch {
    // An id from somewhere else.
    return null;
  }
}

async function start(request: Request, env: ComposeEnv, url: URL): Promise<Response> {
  const user = await userFrom(request, env);
  if (!user) return signInNeeded();
  if (!(await allowed(env.MODEL_LIMIT, `compose:${user.id}`))) return problem(429, "Too many requests at once. Try again in a minute.", { "Retry-After": "60" });
  if (!isJSON(request)) return problem(415, "Send application/json.");
  const raw = await bodyBytes(request, MAX_BODY);
  if (!raw) return problem(413, "That's too much to send at once. Send a smaller photo.");
  const refused = await proveApp(request, env, raw, "Dream's model");
  if (refused) return refused;
  const body = object(raw);
  if (!body) return problem(400, "Expected a JSON object.");
  const checked = readComposeRequest(body);
  if ("error" in checked) return problem(400, checked.error);
  if (!env.PAGE_JOBS) return problem(503, "Pages aren't made on this server yet.");

  const id = env.PAGE_JOBS.newUniqueId();
  const jobID = id.toString();
  // The page counts against the allowance now, under the job's id, as the app's first model
  // request would count it; the job's own requests then count toward the same page.
  const refusal = await admitModel(env, user.id, jobID, await accountOf(env, user.id));
  if (refusal) return refusalResponse(refusal);
  // Where the user is goes with the job beside the request, not in it.
  const { here, ...asked } = checked.request;
  const started = await env.PAGE_JOBS.get(id).fetch("https://page-job/start", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dream-User": user.id },
    body: JSON.stringify({ counted: countsAllowed(request), origin: url.origin, here: hereFor(here, hereOf(request)), request: asked }),
  });
  if (!started.ok) {
    console.error("Page job didn't start", started.status);
    return problem(502, "The page couldn't be started. Try again in a moment.");
  }
  const answer: ComposeStarted = { id: jobID };
  return json(answer);
}
