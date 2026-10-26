// Checks the pure parts of the model proxy, Dream Plus and App Attest in Node, without a Worker:
// verifying what the App Store signs (JWS over Apple-shaped certificate chains), App Attest
// attestations and assertions, the counter window, and what the proxy forwards and counts.
// The source is bundled with esbuild first, since it's TypeScript with extensionless imports.
//
//   node test/billing.mjs

import { build } from "esbuild";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { chatUsage } from "../src/responses.ts";
import { USAGE } from "./stub-xai.mjs";
import { appStoreChain, assertion, attest, attestRoot, jws, requestData, transaction } from "./vectors.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const bundle = await build({
  stdin: {
    contents: ["x509", "appstore", "attest", "model", "usage"].map((name) => `export * as ${name} from "./src/${name}.ts";`).join("\n"),
    resolveDir: root,
    loader: "ts",
  },
  bundle: true,
  format: "esm",
  platform: "neutral",
  write: false,
});
const file = join(mkdtempSync(join(tmpdir(), "dream-billing-")), "bundle.mjs");
writeFileSync(file, bundle.outputFiles[0].text);
const { x509, appstore, attest: attestation, model, usage } = await import(pathToFileURL(file).href);

let failures = 0;
function expect(condition, message) {
  console.log(`${condition ? "  ok  " : "  FAIL"}  ${message}`);
  if (!condition) failures++;
}
async function rejects(promise, message, reason) {
  try {
    await promise;
    expect(false, message);
  } catch (error) {
    expect(reason === undefined || error.message === reason, `${message}${reason !== undefined && error.message !== reason ? ` (but for ${error.message})` : ""}`);
  }
}

console.log("Apple's roots, as pinned");
const g3 = x509.certificate(x509.fromBase64(appstore.APPLE_ROOT_CA_G3));
const attestCA = x509.certificate(x509.fromBase64(attestation.APP_ATTEST_ROOT));
expect(g3.curve === "P-384" && g3.isCA && new Date(g3.notAfter).getUTCFullYear() === 2039, "Apple Root CA - G3 parses: a P-384 CA until 2039");
expect(attestCA.curve === "P-384" && attestCA.isCA && new Date(attestCA.notAfter).getUTCFullYear() === 2045, "Apple App Attestation Root CA parses: a P-384 CA until 2045");
expect(x509.hex(await x509.sha256(g3.der)) === "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179", "G3's fingerprint is Apple's published one");
expect(await x509.verifySignature(await x509.importKey(g3.spki, "P-384"), "P-384", "SHA-384", g3.signature, g3.tbs), "G3's own signature checks out (P-384, SHA-384, DER)");

console.log("App Store JWS");
const chain = appStoreChain();
const roots = [x509.certificate(chain.root)];
const signed = jws(chain, transaction());
const payload = await appstore.verifyJWS(signed, roots);
expect(payload.productId === "xyz.onlychan.dream.plus.monthly" && payload.environment === "Sandbox", "a transaction signed by the chain verifies, and its payload comes back");
const parsed = appstore.asTransaction(payload);
expect(parsed.originalTransactionId === "2000000000000001" && parsed.type === "Auto-Renewable Subscription" && parsed.expiresDate > Date.now(), "and reads as a subscription transaction");
await rejects(appstore.verifyJWS(signed, [g3]), "the same chain isn't trusted when only Apple's root is");
const [head, body, signature] = signed.split(".");
const forged = Buffer.from(JSON.stringify({ ...transaction(), expiresDate: Date.now() + 10 * 365 * 86_400_000 })).toString("base64url");
await rejects(appstore.verifyJWS(`${head}.${forged}.${signature}`, roots), "a changed payload is refused");
await rejects(appstore.verifyJWS(`${head}.${body}.${Buffer.alloc(64).toString("base64url")}`, roots), "a wrong signature is refused");
const unmarked = appStoreChain({ leafMark: false });
await rejects(appstore.verifyJWS(jws(unmarked, transaction()), [x509.certificate(unmarked.root)]), "a leaf without the App Store's mark is refused", "not the App Store's certificates");
const plain = appStoreChain({ intermediateMark: false });
await rejects(appstore.verifyJWS(jws(plain, transaction()), [x509.certificate(plain.root)]), "an intermediate without Apple's WWDR mark is refused");
const expired = appStoreChain({ leafNotAfter: new Date(Date.now() - 86_400_000) });
await rejects(appstore.verifyJWS(jws(expired, transaction()), [x509.certificate(expired.root)]), "a leaf that had expired when it signed is refused", "a certificate wasn't valid then");
const old = await appstore.verifyJWS(jws(expired, transaction({ signedDate: Date.now() - 2 * 86_400_000 })), [x509.certificate(expired.root)]);
expect(old.signedDate < Date.now(), "but what it signed while it was valid still verifies, as Apple's library allows");
const twoCerts = jws(chain, transaction(), { x5c: [chain.leaf, chain.intermediate].map((der) => der.toString("base64")) });
await rejects(appstore.verifyJWS(twoCerts, roots), "x5c must hold three certificates");
await rejects(appstore.verifyJWS(jws(chain, transaction(), { alg: "HS256" }), roots), "only ES256");
await rejects(appstore.verifyJWS("not.a.jws", roots), "garbage is refused");
// An attacker's own chain, with their own root in x5c: the root sent is never trusted.
const attacker = appStoreChain();
await rejects(appstore.verifyJWS(jws(attacker, transaction()), roots), "a chain carrying its own root isn't trusted for that");

console.log("App Attest");
const ca = attestRoot();
const attestRoots = [x509.certificate(ca.root)];
const challenge = Buffer.from("a-challenge-of-thirty-two-bytes!");
const app = "DR99P625RR.xyz.onlychan.Dream";
const made = attest(ca, { challenge, category: 3 });
const result = await attestation.verifyAttestation(made.attestation, made.keyBytes, challenge, app, attestRoots);
expect(result.environment === "development" && result.spki.length === 91, "an attestation verifies: development, with the key to keep");
await rejects(attestation.verifyAttestation(made.attestation, made.keyBytes, Buffer.from("another challenge, not this one!!"), app, attestRoots), "for another challenge, it's refused", "nonce");
await rejects(attestation.verifyAttestation(made.attestation, made.keyBytes, challenge, "DR99P625RR.com.example.Other", attestRoots), "for another app, it's refused", "app");
await rejects(attestation.verifyAttestation(made.attestation, Buffer.alloc(32, 1), challenge, app, attestRoots), "with another key id, it's refused", "key id");
await rejects(attestation.verifyAttestation(made.attestation, made.keyBytes, challenge, app, [attestCA]), "under Apple's root alone, a test chain is refused");
const used = attest(ca, { challenge, counter: 3 });
await rejects(attestation.verifyAttestation(used.attestation, used.keyBytes, challenge, app, attestRoots), "a key that has signed before isn't new", "counter");
const shipped = attest(ca, { challenge, environment: "production", category: 4 });
expect((await attestation.verifyAttestation(shipped.attestation, shipped.keyBytes, challenge, app, attestRoots)).environment === "production", "a production key verifies as production");
const sideloaded = attest(ca, { challenge, category: 6 });
await rejects(attestation.verifyAttestation(sideloaded.attestation, sideloaded.keyBytes, challenge, app, attestRoots), "a launch category other than TestFlight, development or the App Store is refused", "category");

const data = requestData("POST", "/api/model", "1761500000", Buffer.from('{"model":"grok-4.7"}'));
const counter = await attestation.verifyAssertion(assertion(made.device, data, 1), data, result.spki, app);
expect(counter === 1, "an assertion verifies and gives its counter");
await rejects(attestation.verifyAssertion(assertion(made.device, data, 2), requestData("POST", "/api/model", "1761500000", Buffer.from("{}")), result.spki, app), "an assertion for another body is refused");
await rejects(attestation.verifyAssertion(assertion(shipped.device, data, 2), data, result.spki, app), "an assertion by another key is refused");
await rejects(attestation.verifyAssertion(assertion(made.device, data, 2, { appID: "DR99P625RR.com.example.Other" }), data, result.spki, app), "an assertion for another app is refused");

console.log("Assertion counters");
let state = { highest: 0, seen: 0 };
const step = (n) => {
  const next = attestation.advance(state.highest, state.seen, n);
  if (next) state = next;
  return next !== null;
};
expect(step(1) && step(2) && step(5), "rising counters are accepted");
expect(!step(5), "a repeat is refused");
expect(step(4) && step(3), "late ones within the window are accepted once");
expect(!step(4) && !step(3), "and not again");
expect(step(40) && !step(19) && step(25), "too old is refused; within 20 below the highest is fine");

console.log("What the proxy forwards");
const env = { APP_IDS: app, MAX_OUTPUT_TOKENS: "4000" };
const forwarded = model.upstreamBody({ model: "grok-4.7", messages: [{ role: "user", content: "hi" }], stream: true, max_tokens: 90_000, n: 3, search_parameters: { mode: "on" }, reasoning_effort: "low", user: "someone" }, env);
expect(forwarded.max_tokens === 4000 && forwarded.stream_options?.include_usage === true, "max_tokens is capped, and the stream reports usage");
expect(!("n" in forwarded) && !("search_parameters" in forwarded) && !("user" in forwarded), "fields Dream doesn't use never reach xAI");
expect(model.upstreamBody({ messages: [{ role: "user", content: "hi" }] }, env).model === "grok-4.7" && model.upstreamBody({ messages: [{ role: "user", content: "hi" }] }, env).max_tokens === 4000, "no model means the first allowed one, and no max_tokens means the cap");
const refused = (body) => {
  try {
    model.upstreamBody(body, env);
    return false;
  } catch {
    return true;
  }
};
expect(refused({ model: "grok-5-ultra", messages: [{ role: "user", content: "hi" }] }), "a model that isn't on the list is refused");
expect(refused({ model: "grok-4.7", messages: [] }), "no messages is refused");
expect(refused({ model: "grok-4.7", messages: [{ role: "user", content: "hi" }], tools: [{ type: "web_search" }] }), "server-side tools are refused");
expect(refused({ model: "grok-4.7", messages: [{ role: "user", content: [{ type: "image_url", image_url: { url: "https://example.com/a.png" } }] }] }), "pictures by address are refused; only data: pictures go");
expect(!refused({ model: "grok-4.7", messages: [{ role: "user", content: [{ type: "text", text: "what's this" }, { type: "image_url", image_url: { url: "data:image/jpeg;base64,/9j/" } }] }] }), "a photo as data: goes");
expect(refused({ model: "grok-4.7", messages: [{ role: "user", content: "hi" }], reasoning_effort: "xhigh" }), "reasoning effort is low, medium or high");
expect(refused({ model: "grok-4.7", messages: [{ role: "user", content: "hi" }], temperature: 7 }), "temperature is checked");

console.log("What a request costs");
// As model.ts counts it: xAI's Responses usage, translated to chat completions' terms first.
const use = model.useFrom(chatUsage(USAGE), "grok-4.7");
expect(use.tokensIn === 1261 && use.tokensCached === 1152 && use.tokensOut === 65, "reasoning tokens count as output, beside completion tokens");
expect(Math.abs(use.cost - 1184) < 0.001, `xAI's own cost, in millionths of a dollar (${use.cost})`);
const computed = model.useFrom(chatUsage({ ...USAGE, cost_in_usd_ticks: undefined }), "grok-4.7");
expect(Math.abs(computed.cost - 1184) < 0.001, `without it, the price list gives the same (${computed.cost})`);

console.log("Allowances");
expect(usage.allowances({ ALLOWANCES: '{"free":{"pagesPerDay":2}}' }).free.pagesPerDay === 2 && usage.allowances({ ALLOWANCES: '{"free":{"pagesPerDay":2}}' }).plus.pagesPerDay === usage.ALLOWANCES.plus.pagesPerDay, "can be changed by a setting, one at a time");
expect(usage.allowances({ ALLOWANCES: "not json" }).free.pagesPerDay === usage.ALLOWANCES.free.pagesPerDay, "a broken setting leaves them as they are");
expect(usage.dayOf(Date.UTC(2026, 9, 27, 23, 59)) === "2026-10-27" && usage.monthOf(Date.UTC(2026, 9, 27)) === "2026-10", "days and months are UTC");

console.log(failures ? `\n${failures} failed` : "\nAll passed");
process.exit(failures ? 1 : 0);
