// Keeping a quiet stream alive. A model can think for a long while before it says anything (xAI's
// Responses API sends nothing while Grok reasons), and the app gives up on a model that's been
// silent for 45 seconds (ModelActivity). So while nothing comes, a comment goes every few
// seconds, which the app counts as the model working and otherwise ignores.
//
// No imports, so test/unit.mjs runs it in Node.

const BEAT = new TextEncoder().encode(": thinking\n\n");

export function withHeartbeat(upstream: ReadableStream<Uint8Array>, everyMs = 10_000): ReadableStream<Uint8Array> {
  const reader = upstream.getReader();
  // A read that's still waiting carries over to the next pull, so nothing that arrives is lost.
  let waiting: Promise<ReadableStreamReadResult<Uint8Array>> | null = null;
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      waiting ??= reader.read();
      let timer: ReturnType<typeof setTimeout> | null = null;
      const quiet = new Promise<null>((resolve) => {
        timer = setTimeout(() => resolve(null), everyMs);
      });
      const result = await Promise.race([waiting, quiet]);
      clearTimeout(timer);
      if (result === null) {
        controller.enqueue(BEAT);
        return;
      }
      waiting = null;
      if (result.done) {
        controller.close();
        return;
      }
      controller.enqueue(result.value);
    },
    async cancel(reason) {
      await reader.cancel(reason);
    },
  });
}
