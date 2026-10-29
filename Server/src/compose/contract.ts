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
  /** The id the finished page is kept under, in sync and on the phone. The app makes it; for a
   * change, the page's own id. */
  pageID: string;
  /** A change to a page the user has, instead of a new page (Stage 2). `request` is still what
   * the page was first asked for. */
  editing?: ComposeEditing;
  /** Tools only the phone can run: a connected service's (its sign-in never leaves the phone) or
   * a travel time (Apple Maps). The server offers them to the model and asks the phone to run
   * each call (a `deviceTool` event), answered at POST /api/compose/:id/tools. */
  deviceTools?: DeviceToolDefinition[];
}

export interface ComposeEditing {
  /** The page as it is now, as the app's Surface encodes it. */
  surface: unknown;
  /** What the user asked to change, in their words. Absent when `answer` or `again` is set. */
  instruction?: string;
  /** The id of the block they pointed at, if any. */
  focus?: string;
  /** A different answer to one of the questions the page was built from (Composer.rebuild). */
  answer?: { question: unknown; choice: string };
  /** Made again from the request, as it was (after the user connected a service it names). */
  again?: boolean;
}

/** A tool the phone runs, offered to the model like any other. */
export interface DeviceToolDefinition {
  name: string;
  description: string;
  /** JSON Schema for its arguments. */
  parameters: unknown;
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
  /** The phone should run one of its tools and answer at POST /api/compose/:id/tools. If no
   * answer comes in 60 seconds (the app isn't open), the model is told it couldn't be read. */
  | { type: "deviceTool"; call: { id: string; name: string; arguments: string } }
  /** Finished, and kept in sync under the request's pageID as a `surface` item (SurfacePayload). */
  | { type: "done"; surface: unknown; model: string; pageID: string }
  | { type: "failed"; message: string }
);

/** POST /api/compose/:id/answers: the user's answers, as the app's Answer encodes them. */
export interface ComposeAnswers {
  answers: unknown[];
}

/** POST /api/compose/:id/tools: what a device tool returned, as text for the model. */
export interface DeviceToolOutput {
  id: string;
  output: string;
}

/** POST /api/push/devices registers this phone for notifications (a page ready, a question
 * waiting); DELETE /api/push/devices/:token forgets it, as at sign-out. */
export interface PushDevice {
  /** The APNs device token, hex. */
  token: string;
  /** "sandbox" for development builds, "production" for TestFlight and the App Store. */
  environment: "sandbox" | "production";
}

/** What a notification carries for the app to open: the page, and the job while it lasts. */
export interface PushPayload {
  page: string;
  job: string;
  kind: "done" | "asking";
}
