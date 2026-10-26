// A stand-in for appleid.apple.com on this Mac, so signing in and deleting accounts can be tested
// without Apple: test keys of its own to sign identity tokens with, Apple's key list, and the
// token and revoke endpoints, which check the client secret the Worker signs and note what was
// revoked. The Worker only uses it under DEV_LOGIN (APPLE_BASE_URL).

import { createServer } from "node:http";

export const CLIENT_ID = "xyz.onlychan.Dream";
export const TEAM_ID = "TESTTEAM01";
export const KEY_ID = "TESTKEY001";
export const KID = "test-apple-key";
const ISSUER = "https://appleid.apple.com";

export const base64url = (data) =>
  Buffer.from(typeof data === "string" ? data : new Uint8Array(data)).toString("base64url");

export async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Buffer.from(digest).toString("hex");
}

/** An RSA key pair like the ones Apple signs identity tokens with. */
export async function rsaKeys() {
  return crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
}

/** A Sign in with Apple key, as the .p8 file's text, and its public half. */
export async function signInKey() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const pem = `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----`;
  return { pem, publicKey: pair.publicKey };
}

/** A signed token: claims over a header naming `kid`, signed with `privateKey` (RS256). */
export async function signToken(claims, privateKey, { kid = KID, alg = "RS256" } = {}) {
  const input = `${base64url(JSON.stringify({ alg, kid }))}.${base64url(JSON.stringify(claims))}`;
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", privateKey, new TextEncoder().encode(input));
  return `${input}.${base64url(signature)}`;
}

/** The claims of an identity token Apple would give Dream for this nonce. */
export async function identityClaims(sub, nonce, extra = {}) {
  const now = Math.floor(Date.now() / 1000);
  return { iss: ISSUER, aud: CLIENT_ID, iat: now, exp: now + 600, sub, nonce: await sha256Hex(nonce), nonce_supported: true, auth_time: now, ...extra };
}

/** Checks a client secret the way Apple would: ES256 with the key, from the team, for Dream. */
export async function checkClientSecret(secret, publicKey) {
  const [header, claims, signature] = (secret ?? "").split(".");
  if (!signature) return false;
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, Buffer.from(signature, "base64url"), new TextEncoder().encode(`${header}.${claims}`));
  const head = JSON.parse(Buffer.from(header, "base64url").toString());
  const body = JSON.parse(Buffer.from(claims, "base64url").toString());
  const now = Math.floor(Date.now() / 1000);
  return ok && head.alg === "ES256" && head.kid === KEY_ID && body.iss === TEAM_ID && body.sub === CLIENT_ID && body.aud === ISSUER && body.exp > now && body.exp - body.iat <= 15_777_000;
}

/** Starts the stand-in. Authorization codes it accepts are `code-for:<sub>`. */
export async function startAppleStub({ publicJWK, signInPublicKey }) {
  const calls = { keys: 0, token: [], revoke: [] };
  const server = createServer(async (request, response) => {
    const send = (status, body) => {
      response.writeHead(status, { "Content-Type": "application/json" });
      response.end(JSON.stringify(body));
    };
    let text = "";
    for await (const chunk of request) text += chunk;
    const form = new URLSearchParams(text);
    if (request.method === "GET" && request.url === "/auth/keys") {
      calls.keys++;
      return send(200, { keys: [{ ...publicJWK, kid: KID, use: "sig", alg: "RS256" }] });
    }
    if (request.method === "POST" && request.url === "/auth/token") {
      const secretOK = await checkClientSecret(form.get("client_secret"), signInPublicKey);
      const code = form.get("code") ?? "";
      calls.token.push({ secretOK, code, clientID: form.get("client_id"), grant: form.get("grant_type") });
      if (!secretOK) return send(400, { error: "invalid_client" });
      if (!code.startsWith("code-for:")) return send(400, { error: "invalid_grant" });
      const sub = code.slice("code-for:".length);
      const idToken = `${base64url(JSON.stringify({ alg: "RS256", kid: KID }))}.${base64url(JSON.stringify({ iss: ISSUER, aud: CLIENT_ID, sub }))}.c2ln`;
      return send(200, { access_token: `access-${sub}`, token_type: "Bearer", expires_in: 3600, refresh_token: `refresh-${sub}`, id_token: idToken });
    }
    if (request.method === "POST" && request.url === "/auth/revoke") {
      const secretOK = await checkClientSecret(form.get("client_secret"), signInPublicKey);
      calls.revoke.push({ secretOK, token: form.get("token"), hint: form.get("token_type_hint"), clientID: form.get("client_id") });
      return secretOK ? send(200, {}) : send(400, { error: "invalid_client" });
    }
    send(404, { error: "not_found" });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { base: `http://127.0.0.1:${server.address().port}`, calls, stop: () => server.close() };
}
