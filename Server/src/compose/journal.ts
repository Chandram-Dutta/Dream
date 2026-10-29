// What a page did before it stopped to wait on the phone, so it picks up where it was
// (docs/ServerGeneration.md). A call to one of the phone's tools with nobody watching may wait ten
// minutes for the app to open; the job (runner.ts) doesn't hold an alarm open for that, so the
// loop stops and starts again from the top once the phone answers, or its time is up. Everything
// the loop asked of the outside world on the way there is kept here: each answer the model gave
// (a round), what each tool call returned, and what the tools' services gave (Wikipedia, search
// and read, what Dream remembers, the phone's earlier answers). Started again, the loop asks the
// same things in the same order, and is given what it was given then, so it gets back to the
// waiting call with the same transcript, the same pages read and the same page so far, without
// asking the model or the web again, and the model goes on from there. Nothing it said on the way
// is said twice: until it gets further than it got before, its events are kept quiet.
//
// Each step is found by what was asked (the request's JSON, a call's id, a service's arguments)
// and how many times the same was asked before it in this run, so a session written again with
// the same request gets the second answer, as it did the first time. Anything not kept, like a
// stream that was cut off, is asked again, and from there the page goes on as it would.
//
// It also counts what's in flight, so the job stops the loop only when it's waiting on the phone
// and nothing else: a gap check still deciding, or a search beside the call, finishes first.
//
// No imports, so test/compose.mjs runs it in Node.

/** A step's place among those like it, and what it gave before, when the page got this far then. */
export interface Step<T> {
  key: string;
  kept?: T;
}

/** A string's hash, quick enough for a request with a photo in it: two 32-bit halves (cyrb53),
 * with its length beside them. Only steps of one page are told apart by it. */
function hash(text: string): string {
  let a = 0xdeadbeef;
  let b = 0x41c6ce57;
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index);
    a = Math.imul(a ^ code, 2654435761);
    b = Math.imul(b ^ code, 1597334677);
  }
  a = Math.imul(a ^ (a >>> 16), 2246822507) ^ Math.imul(b ^ (b >>> 13), 3266489909);
  b = Math.imul(b ^ (b >>> 16), 2246822507) ^ Math.imul(a ^ (a >>> 13), 3266489909);
  return `${(b >>> 0).toString(36)}${(a >>> 0).toString(36)}.${text.length.toString(36)}`;
}

export class Journal {
  private readonly kept: Map<string, unknown>;
  private readonly asked = new Map<string, number>();
  private inFlight = 0;
  /** Going over what the page did before it stopped: its events are kept quiet until it gets
   * further than that. */
  replaying: boolean;
  /** Told when nothing is in flight any more. */
  onIdle: () => void = () => undefined;

  constructor(entries: [string, unknown][] = [], replaying = false) {
    this.kept = new Map(entries);
    this.replaying = replaying && entries.length > 0;
  }

  /** This step's place, and what it gave before. A step that wasn't kept is new, so from there
   * the page is doing what it hadn't done yet, unless the caller knows better (`fresh` false:
   * the call the page stopped for, which it answers itself). */
  step<T>(kind: string, input: unknown, { fresh = true } = {}): Step<T> {
    const what = `${kind}:${hash(typeof input === "string" ? input : JSON.stringify(input) ?? "")}`;
    const count = this.asked.get(what) ?? 0;
    this.asked.set(what, count + 1);
    const key = `${what}:${count}`;
    if (!this.kept.has(key)) {
      if (fresh) this.replaying = false;
      return { key };
    }
    return { key, kept: this.kept.get(key) as T };
  }

  keep(key: string, value: unknown): void {
    if (value !== undefined) this.kept.set(key, value);
  }

  /** What a step gave before, or what it gives now, kept for next time. */
  async remember<T>(kind: string, input: unknown, work: () => Promise<T>): Promise<T> {
    const { key, kept } = this.step<T>(kind, input);
    if (kept !== undefined) return kept;
    const value = await this.working(work);
    this.keep(key, value);
    return value;
  }

  /** Counts work in flight while it runs. */
  async working<T>(work: () => Promise<T>): Promise<T> {
    this.inFlight += 1;
    try {
      return await work();
    } finally {
      this.inFlight -= 1;
      if (this.inFlight === 0) this.onIdle();
    }
  }

  /** Nothing is in flight: what the page waits on now, it waits on alone. */
  get idle(): boolean {
    return this.inFlight === 0;
  }

  /** Everything kept, to be kept with the job while it waits. */
  entries(): [string, unknown][] {
    return [...this.kept];
  }

  /** How big it is kept, in characters of JSON. */
  get size(): number {
    return JSON.stringify(this.entries()).length;
  }
}
