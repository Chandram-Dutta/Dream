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
   * each call (a `deviceTool` event), answered at POST /api/compose/:id/tools.
   *
   * A travel time is the phone's own `live` tool (LiveTool's definition, as the server has it
   * too): the server offers its `live` once, reads the weather and exchange rates itself, and
   * sends the phone only the calls for a route. Any other tool is a connected service's, and the
   * instructions gain the app's rules for connected services (Prompts.connectionRules) while one
   * is offered. A tool named like another of the server's own (lookup, recall, search, read) is
   * left out. */
  deviceTools?: DeviceToolDefinition[];
}

export interface ComposeEditing {
  /** The page as it is now, as the app's Surface encodes it. */
  surface: unknown;
  /** What the user asked to change, in their words. Absent when `answer` or `again` is set. */
  instruction?: string;
  /** The id of the block they pointed at, if any. */
  focus?: string;
  /** A different answer to one of the questions the page was built from (Composer.rebuild): the
   * question as the page's answers hold it, and the new choice ("" leaves it to Dream). */
  answer?: { question: unknown; choice: string };
  /** Made again from the request, as it was (after the user connected a service it names). */
  again?: boolean;
}
// A change is kept in sync under the request's pageID, onto the item the account already has:
// the page, the turn and the change asked for added to its history and editRequests, its log
// added to, and the user's numbers kept where the change left their inputs as they were. A page
// the account doesn't hold in sync (or deleted) isn't written; the `done` event still carries it.

/** A tool the phone runs, offered to the model like any other. */
export interface DeviceToolDefinition {
  /** As the model calls it: letters, digits, _ and -, up to 64. */
  name: string;
  description: string;
  /** JSON Schema for its arguments. */
  parameters: unknown;
  /** The connected service it's from, like Linear, for saying it couldn't answer. */
  service?: string;
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

/** POST /api/compose/:id/tools: what a device tool returned, as text for the model. Only the
 * page's own account may answer, and only a call still waiting (409 otherwise: it was answered,
 * or its 60 seconds are up and the model was told it couldn't be read). */
export interface DeviceToolOutput {
  id: string;
  output: string;
  /** The live source the call read, as the app's Source encodes it (Dream/Engine/Live.swift),
   * when it read one: a travel time (what the phone's LiveTool declared in its LiveLog), or a
   * connected service's look-up kept current (ConnectionTool.readLive). The page binds its live
   * inputs to it, as to the server's own. Without it, values the output names can't be shown
   * live. */
  source?: unknown;
  /** The connected service whose data the output holds, when the call read one
   * (ConnectionLog.use): the page lists it among its services. */
  service?: string;
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
