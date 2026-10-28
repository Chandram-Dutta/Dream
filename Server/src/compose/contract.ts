// What the app and the server's page loop say to each other (docs/ServerGeneration.md). The app
// starts a page with a ComposeRequest, watches its ComposeEvents, and answers its questions.
//
// No imports, so `npm test` loads it in Node.

/** POST /api/compose */
export interface ComposeRequest {
  /** What the user asked for, in their words. */
  request: string;
  /** A photo to start from: a JPEG, base64, at most 1024 pixels on its longer side. */
  image?: string;
  /** "auto", or a model id from models.ts, as the app sends /api/model. */
  model?: string;
  /** none, low, medium, high or max, as the app sends /api/model. */
  thinking?: string;
  locale: { language: string; region: string; currency: string; measurementSystem: string };
  /** Lines the phone adds below the request, like what it remembers about the user (Prompts.context). */
  context?: string[];
  /** The id the finished page is kept under, in sync and on the phone. The app makes it. */
  pageID: string;
}

/** POST /api/compose → */
export interface ComposeStarted {
  id: string;
}

export type ComposePhase = "researching" | "composing" | "fixing";

/** One thing that happened, as GET /api/compose/:id/events streams it, one per `data:` line. */
export type ComposeEvent = { seq: number } & (
  | { type: "phase"; phase: ComposePhase }
  | { type: "trace"; kind: "search" | "read" | "lookup"; text: string }
  /** The page so far, as the app's Surface decodes it; at most 5 a second. */
  | { type: "surface"; surface: unknown }
  /** Questions the loop waits on, as the app's Asking reads GapCheck's (Dream/Generation/GapCheck.swift). */
  | { type: "asking"; questions: unknown[] }
  | { type: "log"; line: string }
  /** Finished, and kept in sync under the request's pageID as a `surface` item (SurfacePayload). */
  | { type: "done"; surface: unknown; model: string; pageID: string }
  | { type: "failed"; message: string }
);

/** POST /api/compose/:id/answers: the user's answers, as the app's Answer encodes them. */
export interface ComposeAnswers {
  answers: unknown[];
}
