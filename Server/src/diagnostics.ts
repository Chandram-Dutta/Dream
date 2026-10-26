// Crash, hang and slow-launch reports from the app, and a small summary of them for whoever runs
// Dream (migrations/0008_diagnostics.sql).
//
//   POST /api/diagnostics               { format: 1, reports: [...] }  → 202 { accepted }
//   GET  /api/admin/diagnostics?days=7  the summary, with X-Admin-Key  → { byKind, byVersion, perDay, topSignatures, durations }
//
// Reports are anonymous: the app sends no session, and the Worker keeps no address, no account
// and nothing anyone wrote (metrickit.ts says what's in one). Addresses are only rate-limit keys,
// which Cloudflare counts. Rows are deleted after 90 days.

import { adminAccess, type AdminEnv } from "./adminkey";
import { readBody, Rejection } from "./payload";
import { MAX_DIAGNOSTICS_BODY, parseReports, ReportError, type DiagnosticReport, type Kind } from "./metrickit";

export interface DiagnosticsEnv extends AdminEnv {
  DB: D1Database;
  /** Uploads a minute from one address. */
  DIAGNOSTICS_LIMIT?: RateLimit;
}

/** How long reports are kept. */
const KEEP_SECONDS = 90 * 24 * 60 * 60;

const HEADERS = { "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cache-Control": "no-store", "Content-Type": "application/json; charset=utf-8" };

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...HEADERS, ...headers } });
}

function problem(status: number, message: string, headers: Record<string, string> = {}): Response {
  return json({ error: message }, status, headers);
}

const now = () => Math.floor(Date.now() / 1000);

/** Stores an upload's reports. */
export async function receiveDiagnostics(request: Request, env: DiagnosticsEnv, ctx: ExecutionContext): Promise<Response> {
  if (env.DIAGNOSTICS_LIMIT) {
    const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const { success } = await env.DIAGNOSTICS_LIMIT.limit({ key: `diagnostics:${address}` });
    if (!success) return problem(429, "Too many reports at once. Try again in a minute.", { "Retry-After": "60" });
  }
  if (!/^application\/json(\s*;|$)/i.test(request.headers.get("Content-Type") ?? "")) return problem(415, "Send reports as application/json.");
  let reports: DiagnosticReport[];
  try {
    reports = parseReports(await readBody(request, MAX_DIAGNOSTICS_BODY));
  } catch (error) {
    if (error instanceof Rejection) return problem(error.status, error.status === 413 ? "Those reports are too big." : error.message);
    if (error instanceof ReportError) return problem(400, error.message);
    throw error;
  }
  const at = now();
  const day = new Date(at * 1000).toISOString().slice(0, 10);
  const insert = env.DB.prepare(
    `INSERT INTO diagnostics (kind, received_at, day, app_version, app_build, os_version, device, test_flight, period_start, period_end,
       duration, exception_type, exception_code, signal, exception_name, exception_class, termination_reason, signature, stack)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  );
  await env.DB.batch(
    reports.map((report) =>
      insert.bind(
        report.kind, at, day, report.app, report.build, report.os, report.device, report.testFlight ? 1 : 0, report.start, report.end,
        report.duration, report.exceptionType, report.exceptionCode, report.signal, report.exceptionName, report.exceptionClass,
        report.terminationReason, report.signature, report.stack,
      ),
    ),
  );
  ctx.waitUntil(env.DB.prepare("DELETE FROM diagnostics WHERE received_at < ?").bind(at - KEEP_SECONDS).run().then(() => undefined));
  return json({ accepted: reports.length }, 202);
}

interface Durations {
  count: number;
  average: number | null;
  median: number | null;
  p90: number | null;
  max: number | null;
}

/** What's come in over the last `days` days: enough to see what's wrong, and in which version. */
export async function diagnosticsSummary(request: Request, env: DiagnosticsEnv, url: URL): Promise<Response> {
  const access = await adminAccess(request, env);
  if (access === "unset") return problem(404, "Not found.");
  if (access === "no") return problem(403, "Not allowed.");
  const days = Number(url.searchParams.get("days") ?? "7");
  if (!Number.isInteger(days) || days < 1 || days > 90) return problem(400, "days is a whole number from 1 to 90.");
  const since = now() - days * 24 * 60 * 60;

  const [kinds, versions, perDay, signatures, durationRows] = await env.DB.batch([
    env.DB.prepare("SELECT kind, COUNT(*) AS count FROM diagnostics WHERE received_at >= ? GROUP BY kind").bind(since),
    env.DB.prepare(
      `SELECT app_version, app_build, kind, COUNT(*) AS count FROM diagnostics WHERE received_at >= ?
       GROUP BY app_version, app_build, kind ORDER BY app_version DESC, app_build DESC`,
    ).bind(since),
    env.DB.prepare("SELECT day, kind, COUNT(*) AS count FROM diagnostics WHERE received_at >= ? GROUP BY day, kind ORDER BY day").bind(since),
    // SQLite takes the bare columns from the row with the latest received_at.
    env.DB.prepare(
      `SELECT kind, signature, COUNT(*) AS count, MAX(received_at) AS last_seen, app_version, app_build FROM diagnostics
       WHERE received_at >= ? GROUP BY kind, signature ORDER BY count DESC, last_seen DESC LIMIT 20`,
    ).bind(since),
    env.DB.prepare(
      `SELECT kind, COUNT(duration) AS count, AVG(duration) AS average, MAX(duration) AS max FROM diagnostics
       WHERE received_at >= ? AND duration IS NOT NULL GROUP BY kind`,
    ).bind(since),
  ]);

  const byKind: Record<Kind, number> = { crash: 0, hang: 0, launch: 0 };
  for (const row of kinds.results as { kind: Kind; count: number }[]) byKind[row.kind] = row.count;

  const byVersion: { app: string; build: string; crash: number; hang: number; launch: number }[] = [];
  for (const row of versions.results as { app_version: string; app_build: string; kind: Kind; count: number }[]) {
    let entry = byVersion.find((item) => item.app === row.app_version && item.build === row.app_build);
    if (!entry) byVersion.push((entry = { app: row.app_version, build: row.app_build, crash: 0, hang: 0, launch: 0 }));
    entry[row.kind] = row.count;
  }

  const timeline: { day: string; crash: number; hang: number; launch: number }[] = [];
  for (const row of perDay.results as { day: string; kind: Kind; count: number }[]) {
    let entry = timeline.find((item) => item.day === row.day);
    if (!entry) timeline.push((entry = { day: row.day, crash: 0, hang: 0, launch: 0 }));
    entry[row.kind] = row.count;
  }

  const durations: Record<"hang" | "launch", Durations> = {
    hang: { count: 0, average: null, median: null, p90: null, max: null },
    launch: { count: 0, average: null, median: null, p90: null, max: null },
  };
  for (const row of durationRows.results as { kind: Kind; count: number; average: number; max: number }[]) {
    if (row.kind === "crash") continue;
    const at = (fraction: number) =>
      env.DB.prepare("SELECT duration FROM diagnostics WHERE kind = ? AND received_at >= ? AND duration IS NOT NULL ORDER BY duration LIMIT 1 OFFSET ?")
        .bind(row.kind, since, Math.floor(fraction * (row.count - 1)))
        .first<number>("duration");
    const [median, p90] = await Promise.all([at(0.5), at(0.9)]);
    durations[row.kind] = { count: row.count, average: round(row.average), median: round(median), p90: round(p90), max: round(row.max) };
  }

  return json({
    days,
    since: new Date(since * 1000).toISOString(),
    total: byKind.crash + byKind.hang + byKind.launch,
    byKind,
    byVersion,
    perDay: timeline,
    topSignatures: (signatures.results as { kind: Kind; signature: string; count: number; last_seen: number; app_version: string; app_build: string }[]).map((row) => ({
      kind: row.kind,
      signature: row.signature,
      count: row.count,
      lastSeen: new Date(row.last_seen * 1000).toISOString(),
      latest: `${row.app_version} (${row.app_build})`,
    })),
    durations,
  });
}

const round = (seconds: number | null) => (seconds === null ? null : Math.round(seconds * 100) / 100);
