// What an account may spend, and what it pays for: the model (model.ts), its allowance
// (usage.ts), Dream Plus (appstore.ts) and the app's proof that it's the app (attest.ts).
//
//   POST /api/model                    the model, for signed-in users of the app
//   GET  /api/usage                    the plan, and pages used and left
//   POST /api/appstore/transactions    purchases the app made or restored
//   POST /api/appstore/notifications   App Store Server Notifications v2
//   POST /api/attest/challenge, /api/attest/key   App Attest

import { receiveNotification, receiveTransactions } from "./appstore";
import { challenge, register } from "./attest";
import { signInNeeded, userFrom } from "./auth";
import { model, type ModelEnv } from "./model";
import { bodyBytes, isJSON, json, object, problem } from "./reply";
import { status } from "./usage";

export type PlanEnv = ModelEnv;

const only = (method: string) => problem(405, `Only ${method}.`, { Allow: method });

/** The routes here, or null for any other path. */
export async function routePlan(request: Request, env: PlanEnv, ctx: ExecutionContext, url: URL): Promise<Response | null> {
  switch (url.pathname) {
    case "/api/model":
      return request.method === "POST" ? model(request, env, ctx) : only("POST");
    case "/api/usage": {
      if (request.method !== "GET") return only("GET");
      const user = await userFrom(request, env);
      return user ? json(await status(env, user.id)) : signInNeeded();
    }
    case "/api/appstore/transactions": {
      if (request.method !== "POST") return only("POST");
      const user = await userFrom(request, env);
      if (!user) return signInNeeded();
      const body = await jsonBody(request, 200_000);
      if (body instanceof Response) return body;
      const verdict = await receiveTransactions(env, user.id, body);
      return verdict.ok ? json(await status(env, user.id)) : problem(verdict.status, verdict.message);
    }
    case "/api/appstore/notifications": {
      if (request.method !== "POST") return only("POST");
      const body = await jsonBody(request, 100_000);
      if (body instanceof Response) return body;
      const verdict = await receiveNotification(env, body);
      return verdict.ok ? json({ ok: true }) : problem(verdict.status, verdict.message);
    }
    case "/api/attest/challenge": {
      if (request.method !== "POST") return only("POST");
      const user = await userFrom(request, env);
      return user ? challenge(env, user.id) : signInNeeded();
    }
    case "/api/attest/key": {
      if (request.method !== "POST") return only("POST");
      const user = await userFrom(request, env);
      return user ? register(request, env, user.id) : signInNeeded();
    }
    default:
      return null;
  }
}

async function jsonBody(request: Request, max: number): Promise<Record<string, unknown> | Response> {
  if (!isJSON(request)) return problem(415, "Send application/json.");
  const raw = await bodyBytes(request, max);
  if (!raw) return problem(413, "That's too big.");
  return object(raw) ?? problem(400, "Expected a JSON object.");
}
