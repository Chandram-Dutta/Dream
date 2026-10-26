// Checks accounts: first the identity token checks on their own, with test keys (signature,
// algorithm, issuer, audience, expiry and nonce), and the client secret that revokes Apple's
// tokens; then the routes end to end under `wrangler dev`, with a stand-in for Apple on this Mac
// (test/stub-apple.mjs): signing in, a token used twice, devices and signing them out, export,
// and deletion, which erases everything and asks Apple to forget Dream.
//
//   node test/accounts.mjs

import { spawn, execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { clientSecret, revoke, TokenRefused, verifyIdentityToken } from "../src/apple.ts";
import { CLIENT_ID, KEY_ID, KID, TEAM_ID, checkClientSecret, identityClaims, rsaKeys, signInKey, signToken, startAppleStub } from "./stub-apple.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
let failures = 0;

function expect(condition, message) {
  console.log(`${condition ? "  ok  " : "  FAIL"}  ${message}`);
  if (!condition) failures++;
}

const apple = await rsaKeys();
const impostor = await rsaKeys();
const signing = await signInKey();
const publicJWK = await crypto.subtle.exportKey("jwk", apple.publicKey);

async function refusal(token, nonce, options = {}) {
  try {
    await verifyIdentityToken(token, { audiences: [CLIENT_ID], nonce, key: async (kid) => (kid === KID ? apple.publicKey : null), ...options });
    return "accepted";
  } catch (error) {
    return error instanceof TokenRefused ? error.reason : `threw ${error}`;
  }
}

async function unitChecks() {
  console.log("Identity tokens");
  const nonce = "a-random-nonce-made-by-the-app-0123";
  const good = await signToken(await identityClaims("001234.abc", nonce, { email: "x7@privaterelay.appleid.com", email_verified: true, is_private_email: true }), apple.privateKey);
  const identity = await verifyIdentityToken(good, { audiences: [CLIENT_ID], nonce, key: async () => apple.publicKey });
  expect(identity.sub === "001234.abc" && identity.email === "x7@privaterelay.appleid.com" && identity.isPrivateEmail, "a good token: who it's for, and their Hide My Email address");
  expect((await refusal(await signToken(await identityClaims("s", nonce), impostor.privateKey), nonce)) === "signature", "signed with another key: signature");
  const [header, , signature] = good.split(".");
  const altered = Buffer.from(JSON.stringify({ ...(await identityClaims("someone-else", nonce)) })).toString("base64url");
  expect((await refusal(`${header}.${altered}.${signature}`, nonce)) === "signature", "claims changed after signing: signature");
  const unsigned = `${Buffer.from(JSON.stringify({ alg: "none", kid: KID })).toString("base64url")}.${good.split(".")[1]}.AA`;
  expect((await refusal(unsigned, nonce)) === "algorithm", "alg none: algorithm");
  expect((await refusal(await signToken(await identityClaims("s", nonce), apple.privateKey, { alg: "HS256" }), nonce)) === "algorithm", "a symmetric algorithm: algorithm");
  expect((await refusal(await signToken(await identityClaims("s", nonce), apple.privateKey, { kid: "unknown" }), nonce)) === "key", "a key Apple doesn't publish: key");
  expect((await refusal(await signToken(await identityClaims("s", nonce, { iss: "https://evil.example" }), apple.privateKey), nonce)) === "issuer", "another issuer: issuer");
  expect((await refusal(await signToken(await identityClaims("s", nonce, { aud: "com.other.app" }), apple.privateKey), nonce)) === "audience", "another app's token: audience");
  expect((await refusal(await signToken(await identityClaims("s", nonce, { aud: ["com.other.app", CLIENT_ID] }), apple.privateKey), nonce)) === "accepted", "an audience list that names Dream");
  expect((await refusal(good, nonce, { audiences: [] })) === "audience", "no audience set up: audience");
  const past = Math.floor(Date.now() / 1000) - 3_600;
  expect((await refusal(await signToken(await identityClaims("s", nonce, { iat: past - 600, exp: past }), apple.privateKey), nonce)) === "expired", "an hour old: expired");
  const recent = Math.floor(Date.now() / 1000) - 30;
  expect((await refusal(await signToken(await identityClaims("s", nonce, { exp: recent }), apple.privateKey), nonce)) === "accepted", "seconds past expiry, within the clock leeway");
  expect((await refusal(await signToken(await identityClaims("s", nonce, { iat: Math.floor(Date.now() / 1000) + 3_600 }), apple.privateKey), nonce)) === "early", "issued in the future: early");
  expect((await refusal(good, "some-other-nonce-0123456789")) === "nonce", "made for another sign-in: nonce");
  const noNonce = await identityClaims("s", nonce);
  delete noNonce.nonce;
  expect((await refusal(await signToken(noNonce, apple.privateKey), nonce)) === "nonce", "no nonce in the token: nonce");
  expect((await refusal(await signToken(await identityClaims("", nonce), apple.privateKey), nonce)) === "subject", "no subject: subject");
  expect((await refusal("abc.def", nonce)) === "malformed" && (await refusal("a.b!.c", nonce)) === "malformed" && (await refusal("", nonce)) === "malformed", "not a token: malformed");

  console.log("Client secret");
  const env = { APPLE_CLIENT_ID: CLIENT_ID, APPLE_TEAM_ID: TEAM_ID, APPLE_KEY_ID: KEY_ID, APPLE_PRIVATE_KEY: signing.pem };
  expect(await checkClientSecret(await clientSecret(env), signing.publicKey), "signed ES256 with the key, from the team, for Dream, briefly");
  expect(await checkClientSecret(await clientSecret({ ...env, APPLE_PRIVATE_KEY: signing.pem.replace(/\n/g, "\\n") }), signing.publicKey), "the key also reads with its line breaks written as \\n");
  expect((await clientSecret({ ...env, APPLE_PRIVATE_KEY: undefined })) === null, "none without the key");
  expect((await revoke({ ...env, APPLE_PRIVATE_KEY: undefined }, "code-for:x", "x")) === "no key", "without the key, revoking is left pending");
  expect((await revoke(env, null, "x")) === "no code", "without a code from the app, too");
}

async function startLocal(stub) {
  const env = { ...process.env, WRANGLER_SEND_METRICS: "false" };
  execFileSync("npx", ["wrangler", "d1", "migrations", "apply", "dream-share", "--local"], { cwd: root, env, stdio: "ignore" });
  const port = 20_000 + Math.floor(Math.random() * 2_000);
  // These take the place of anything in .dev.vars. The key goes with its line breaks written out.
  const vars = [
    "DEV_LOGIN:1",
    `APPLE_BASE_URL:${stub.base}`,
    `APPLE_CLIENT_ID:${CLIENT_ID}`,
    `APPLE_TEAM_ID:${TEAM_ID}`,
    `APPLE_KEY_ID:${KEY_ID}`,
    `APPLE_PRIVATE_KEY:${signing.pem.replace(/\n/g, "\\n")}`,
  ].flatMap((pair) => ["--var", pair]);
  const child = spawn("npx", ["wrangler", "dev", "--port", String(port), "--ip", "127.0.0.1", ...vars], { cwd: root, env, stdio: ["ignore", "pipe", "pipe"] });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("wrangler dev didn't start in 60 s")), 60_000);
    const watch = (chunk) => {
      if (String(chunk).includes("Ready on")) {
        clearTimeout(timer);
        resolve();
      }
    };
    child.stdout.on("data", watch);
    child.stderr.on("data", watch);
    child.on("exit", (code) => reject(new Error(`wrangler dev exited with ${code}`)));
  });
  return { base: `http://127.0.0.1:${port}`, stop: () => child.kill("SIGTERM") };
}

async function endToEnd(base, stub) {
  const call = (path, { method = "GET", token, body, type = "application/json" } = {}) =>
    fetch(`${base}${path}`, {
      method,
      headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { "Content-Type": type } : {}) },
      body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    });
  const sub = `001234.${randomUUID().replace(/-/g, "")}`;
  const signIn = async (who, extra = {}, fields = {}) => {
    const nonce = randomUUID() + randomUUID();
    const identityToken = await signToken(await identityClaims(who, nonce, extra), apple.privateKey);
    const response = await call("/api/auth/apple", { method: "POST", body: { identityToken, nonce, ...fields } });
    return { response, identityToken, nonce };
  };

  console.log("Signing in");
  let response = await call("/api/auth/apple");
  expect(response.status === 405, "only POST");
  response = await call("/api/auth/apple", { method: "POST", body: "{}", type: "text/plain" });
  expect(response.status === 415, "only application/json");
  response = await call("/api/auth/apple", { method: "POST", body: { nonce: "a-random-nonce-made-by-the-app" } });
  expect(response.status === 400, "an identity token is needed");
  const first = await signIn(sub, { email: "q8x2@privaterelay.appleid.com", email_verified: "true", is_private_email: "true" }, { name: "  Asha\u0000 Rao ", device: "iPhone · iOS 27.0" });
  const signedIn = await first.response.json();
  expect(first.response.status === 201 && /^[A-Za-z0-9_-]{40,}$/.test(signedIn.token ?? "") && signedIn.expiresAt > Date.now() / 1000, "a new session");
  expect(signedIn.isNew === true && signedIn.user?.name === "Asha Rao" && signedIn.user?.email === "q8x2@privaterelay.appleid.com" && signedIn.user?.isPrivateEmail === true, "a new account, with the name the app sent and the email from the token");
  response = await call("/api/auth/apple", { method: "POST", body: { identityToken: first.identityToken, nonce: first.nonce } });
  expect(response.status === 401, "the same token can't sign in twice");
  const otherNonce = randomUUID() + randomUUID();
  response = await call("/api/auth/apple", { method: "POST", body: { identityToken: await signToken(await identityClaims(sub, otherNonce), apple.privateKey), nonce: "not-the-nonce-it-was-made-for" } });
  expect(response.status === 401, "a token made for another sign-in is refused");
  response = await call("/api/auth/apple", { method: "POST", body: { identityToken: await signToken(await identityClaims(sub, otherNonce), impostor.privateKey), nonce: otherNonce } });
  expect(response.status === 401, "a token Apple didn't sign is refused");
  const second = await signIn(sub, {}, { name: "Someone Else", device: "iPhone · iOS 27.1" });
  const again = await second.response.json();
  expect(second.response.status === 201 && again.isNew === false && again.user?.id === signedIn.user?.id, "signing in again finds the same account");
  expect(again.user?.name === "Asha Rao" && again.user?.email === "q8x2@privaterelay.appleid.com", "and keeps the name and email from the first time");

  console.log("The account");
  response = await call("/api/me");
  expect(response.status === 401 && response.headers.get("www-authenticate") === "Bearer", "signed out, it's 401");
  response = await call("/api/me", { token: again.token });
  const me = await response.json();
  expect(response.status === 200 && me.name === "Asha Rao" && me.isPrivateEmail === true && typeof me.createdAt === "number", "name, email and since when");
  expect(response.headers.get("cache-control") === "no-store", "never cached");

  console.log("Devices");
  response = await call("/api/me/sessions", { token: again.token });
  const { sessions } = await response.json();
  expect(response.status === 200 && sessions?.length === 2, "both devices");
  const here = sessions.find((session) => session.current);
  const there = sessions.find((session) => !session.current);
  expect(here?.device === "iPhone · iOS 27.1" && there?.device === "iPhone · iOS 27.0", "which one is asking, and what each is");
  expect(!JSON.stringify(sessions).includes(again.token) && !JSON.stringify(sessions).includes(signedIn.token), "no session tokens");
  const stranger = await (await call("/api/dev/session?user=stranger", { method: "POST" })).json();
  response = await call(`/api/me/sessions/${there.id}`, { method: "DELETE", token: stranger.token });
  expect(response.status === 404, "someone else can't sign a device out");
  response = await call(`/api/me/sessions/${there.id}`, { method: "DELETE", token: again.token });
  expect(response.status === 204, "signing the other device out");
  response = await call("/api/me", { token: signedIn.token });
  expect(response.status === 401, "and its session stops working");
  response = await call(`/api/me/sessions/${"0".repeat(64)}`, { method: "DELETE", token: again.token });
  expect(response.status === 404, "a device that isn't signed in is 404");

  console.log("Export");
  response = await call("/api/me/export", { token: again.token });
  expect(response.status === 405, "only POST");
  response = await call("/api/me/export", { method: "POST", token: again.token });
  const exported = await response.json();
  expect(response.status === 200 && /attachment; filename="dream-data-\d{4}-\d{2}-\d{2}\.json"/.test(response.headers.get("content-disposition") ?? ""), "a JSON file");
  expect(exported.account?.name === "Asha Rao" && exported.account?.email === "q8x2@privaterelay.appleid.com" && exported.sessions?.length === 1, "the account and its devices");
  expect(!/[0-9a-f]{64}/.test(JSON.stringify(exported)) && !JSON.stringify(exported).includes(again.token) && !JSON.stringify(exported).includes(sub), "no tokens, their hashes, or Apple's id");

  console.log("Deleting");
  response = await call("/api/me", { method: "DELETE", token: again.token, body: { authorizationCode: `code-for:${sub}` } });
  const deleted = await response.json();
  expect(response.status === 200 && deleted.deleted === true && deleted.appleRevoked === true, "deleted, and Apple asked to forget Dream");
  const revoked = stub.calls.revoke.at(-1);
  expect(stub.calls.token.at(-1)?.secretOK && revoked?.secretOK && revoked.token === `refresh-${sub}` && revoked.hint === "refresh_token" && revoked.clientID === CLIENT_ID, "the code exchanged and its refresh token revoked, with a client secret Apple accepts");
  response = await call("/api/me", { token: again.token });
  expect(response.status === 401, "every session stops at once");
  const back = await (await signIn(sub, {}, { name: "Asha" })).response.json();
  expect(back.isNew === true && back.user?.id !== signedIn.user?.id && back.user?.email === null, "signing in again starts a new, empty account");
  const exportedAgain = await (await call("/api/me/export", { method: "POST", token: back.token })).json();
  expect(exportedAgain.sessions?.length === 1 && exportedAgain.account?.name === "Asha", "nothing of the old one is left");

  const revokes = stub.calls.revoke.length;
  response = await call("/api/me", { method: "DELETE", token: back.token, body: { authorizationCode: "code-for:someone-else" } });
  expect((await response.json()).appleRevoked === false && stub.calls.revoke.length === revokes, "a code for another Apple ID revokes nothing, and the account is still deleted");
  response = await call("/api/me", { method: "DELETE", token: stranger.token });
  expect(response.status === 200 && (await response.json()).appleRevoked === false, "without a code, deleting still erases everything");
  response = await call("/api/me", { token: stranger.token });
  expect(response.status === 401, "and signs out");

  console.log("Rate limiting");
  let limited = false;
  for (let i = 0; i < 15 && !limited; i++) limited = (await call("/api/auth/apple", { method: "POST", body: {} })).status === 429;
  expect(limited, "too many sign-ins from one address are refused for a while");
}

await unitChecks();
const stub = await startAppleStub({ publicJWK, signInPublicKey: signing.publicKey });
let server;
try {
  server = await startLocal(stub);
  await endToEnd(server.base, stub);
} catch (error) {
  console.log(`  FAIL  ${error.stack ?? error}`);
  failures++;
} finally {
  server?.stop();
  stub.stop();
}
console.log(failures ? `\n${failures} failed` : "\nAll passed");
process.exit(failures ? 1 : 0);
