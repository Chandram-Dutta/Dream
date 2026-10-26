// Test vectors for what Apple signs, made on this Mac: certificate chains shaped like the App
// Store's and App Attest's (with Apple's marker extensions), JWS signed the way the App Store
// signs transactions and notifications, and App Attest attestation and assertion objects. Their
// roots are made here too, so the server is told to trust them only in local development
// (APPSTORE_TEST_ROOT and ATTEST_TEST_ROOT, honoured with DEV_LOGIN=1).

import { createHash, generateKeyPairSync, sign } from "node:crypto";

// MARK: - DER

const length = (n) => (n < 128 ? [n] : n < 256 ? [0x81, n] : n < 65_536 ? [0x82, n >> 8, n & 255] : [0x83, n >> 16, (n >> 8) & 255, n & 255]);
export const tlv = (tag, ...parts) => {
  const body = Buffer.concat(parts.map((part) => Buffer.from(part)));
  return Buffer.concat([Buffer.from([tag, ...length(body.length)]), body]);
};
const seq = (...parts) => tlv(0x30, ...parts);
const set = (...parts) => tlv(0x31, ...parts);
const integer = (n) => tlv(0x02, Buffer.from([n & 0x7f]));
const bool = (value) => tlv(0x01, Buffer.from([value ? 0xff : 0]));
const octets = (bytes) => tlv(0x04, bytes);
const bits = (bytes) => tlv(0x03, Buffer.concat([Buffer.from([0]), Buffer.from(bytes)]));
const explicit = (n, ...parts) => tlv(0xa0 + n, ...parts);
const NULL = Buffer.from([0x05, 0x00]);
function oid(text) {
  const [a, b, ...rest] = text.split(".").map(Number);
  const bytes = [40 * a + b];
  for (const part of rest) {
    const chunk = [part & 0x7f];
    let value = Math.floor(part / 128);
    while (value > 0) {
      chunk.unshift((value & 0x7f) | 0x80);
      value = Math.floor(value / 128);
    }
    bytes.push(...chunk);
  }
  return tlv(0x06, Buffer.from(bytes));
}
const name = (cn) => seq(set(seq(oid("2.5.4.3"), tlv(0x0c, Buffer.from(cn)))));
const time = (date) => tlv(0x18, Buffer.from(date.toISOString().replace(/[-:T]/g, "").slice(0, 14) + "Z"));

export const key = (curve = "P-256") => generateKeyPairSync("ec", { namedCurve: curve === "P-256" ? "prime256v1" : "secp384r1" });

/** A certificate for `publicKey`, signed by `issuerKey`. */
export function certificate({ subject, issuer = subject, publicKey, issuerKey, issuerCurve = "P-384", ca = false, extensions = [], notBefore = new Date("2020-01-01"), notAfter = new Date("2045-01-01"), serial = 1 }) {
  const algorithm = seq(oid(issuerCurve === "P-256" ? "1.2.840.10045.4.3.2" : "1.2.840.10045.4.3.3"));
  const list = [seq(oid("2.5.29.19"), bool(true), octets(ca ? seq(bool(true)) : seq())), ...extensions.map(([id, value]) => seq(oid(id), octets(value)))];
  const tbs = seq(explicit(0, integer(2)), integer(serial), algorithm, name(issuer), seq(time(notBefore), time(notAfter)), name(subject), publicKey.export({ type: "spki", format: "der" }), explicit(3, seq(...list)));
  const signature = sign(issuerCurve === "P-256" ? "sha256" : "sha384", tbs, { key: issuerKey, dsaEncoding: "der" });
  return seq(tbs, algorithm, bits(signature));
}

// MARK: - The App Store

const base64url = (bytes) => Buffer.from(bytes).toString("base64url");

/** A chain like the App Store's: root, Apple's WWDR intermediate, and the signing leaf. */
export function appStoreChain({ leafMark = true, intermediateMark = true, leafNotAfter } = {}) {
  const root = key("P-384");
  const intermediate = key("P-384");
  const leaf = key("P-256");
  const rootDER = certificate({ subject: "Test Root CA - G3", publicKey: root.publicKey, issuerKey: root.privateKey, ca: true });
  const intermediateDER = certificate({ subject: "Test WWDR CA", issuer: "Test Root CA - G3", publicKey: intermediate.publicKey, issuerKey: root.privateKey, ca: true, extensions: intermediateMark ? [["1.2.840.113635.100.6.2.1", NULL]] : [], serial: 2 });
  const leafDER = certificate({ subject: "Test App Store signing", issuer: "Test WWDR CA", publicKey: leaf.publicKey, issuerKey: intermediate.privateKey, extensions: leafMark ? [["1.2.840.113635.100.6.11.1", NULL]] : [], serial: 3, ...(leafNotAfter ? { notAfter: leafNotAfter } : {}) });
  return { root: rootDER, intermediate: intermediateDER, leaf: leafDER, leafKey: leaf.privateKey, rootBase64: rootDER.toString("base64") };
}

/** A JWS signed by the chain's leaf, ES256, with the chain in x5c. */
export function jws(chain, payload, header = {}) {
  const head = base64url(JSON.stringify({ alg: "ES256", x5c: [chain.leaf, chain.intermediate, chain.root].map((der) => der.toString("base64")), ...header }));
  const body = base64url(JSON.stringify(payload));
  const signature = sign("sha256", Buffer.from(`${head}.${body}`), { key: chain.leafKey, dsaEncoding: "ieee-p1363" });
  return `${head}.${body}.${base64url(signature)}`;
}

/** A subscription transaction, as JWSTransactionDecodedPayload describes it. */
export function transaction(overrides = {}) {
  const now = Date.now();
  return {
    transactionId: "2000000000000001",
    originalTransactionId: "2000000000000001",
    webOrderLineItemId: "2000000000000002",
    bundleId: "xyz.onlychan.Dream",
    productId: "xyz.onlychan.dream.plus.monthly",
    subscriptionGroupIdentifier: "21000000",
    purchaseDate: now - 60_000,
    originalPurchaseDate: now - 60_000,
    expiresDate: now + 30 * 86_400_000,
    quantity: 1,
    type: "Auto-Renewable Subscription",
    inAppOwnershipType: "PURCHASED",
    signedDate: now,
    environment: "Sandbox",
    transactionReason: "PURCHASE",
    storefront: "IND",
    storefrontId: "143467",
    price: 799000,
    currency: "INR",
    ...overrides,
  };
}

// MARK: - CBOR, for App Attest

export function cbor(value) {
  const head = (major, n) => {
    if (n < 24) return Buffer.from([(major << 5) | n]);
    if (n < 256) return Buffer.from([(major << 5) | 24, n]);
    if (n < 65_536) return Buffer.from([(major << 5) | 25, n >> 8, n & 255]);
    return Buffer.from([(major << 5) | 26, (n >>> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255]);
  };
  if (typeof value === "number") return value >= 0 ? head(0, value) : head(1, -1 - value);
  if (typeof value === "string") return Buffer.concat([head(3, Buffer.byteLength(value)), Buffer.from(value)]);
  if (Buffer.isBuffer(value) || value instanceof Uint8Array) return Buffer.concat([head(2, value.length), Buffer.from(value)]);
  if (Array.isArray(value)) return Buffer.concat([head(4, value.length), ...value.map(cbor)]);
  const entries = value instanceof Map ? [...value.entries()] : Object.entries(value);
  return Buffer.concat([head(5, entries.length), ...entries.flatMap(([k, v]) => [cbor(k), cbor(v)])]);
}

const sha256 = (...parts) => createHash("sha256").update(Buffer.concat(parts.map((part) => Buffer.from(part)))).digest();

/** A chain like App Attest's root and intermediate, ready to certify device keys. */
export function attestRoot() {
  const root = key("P-384");
  const intermediate = key("P-384");
  const rootDER = certificate({ subject: "Test App Attestation Root CA", publicKey: root.publicKey, issuerKey: root.privateKey, ca: true });
  const intermediateDER = certificate({ subject: "Test App Attestation CA 1", issuer: "Test App Attestation Root CA", publicKey: intermediate.publicKey, issuerKey: root.privateKey, ca: true, serial: 2 });
  return { root: rootDER, intermediate: intermediateDER, intermediateKey: intermediate.privateKey, rootBase64: rootDER.toString("base64") };
}

/** A device key and its App Attest attestation for `challenge`, as `attestKey` would make it. */
export function attest(ca, { appID = "DR99P625RR.xyz.onlychan.Dream", challenge, environment = "development", counter = 0, category } = {}) {
  const device = key("P-256");
  const spki = device.publicKey.export({ type: "spki", format: "der" });
  const point = spki.subarray(spki.length - 65);
  const keyID = sha256(point);
  const cose = cbor(new Map([[1, 2], [3, -7], [-1, 1], [-2, point.subarray(1, 33)], [-3, point.subarray(33)]]));
  const aaguid = Buffer.from(environment === "production" ? "appattest\0\0\0\0\0\0\0" : "appattestdevelop");
  const extensions = category === undefined ? Buffer.alloc(0) : cbor({ apple_validation_category_01: category, apple_bundle_version_01: "1" });
  const counterBytes = Buffer.alloc(4);
  counterBytes.writeUInt32BE(counter);
  const authData = Buffer.concat([sha256(Buffer.from(appID)), Buffer.from([0x40 | (extensions.length ? 0x80 : 0)]), counterBytes, aaguid, Buffer.from([0, 32]), keyID, cose, extensions]);
  const nonce = sha256(authData, sha256(challenge));
  const credential = certificate({ subject: keyID.toString("hex"), issuer: "Test App Attestation CA 1", publicKey: device.publicKey, issuerKey: ca.intermediateKey, extensions: [["1.2.840.113635.100.8.2", seq(explicit(1, octets(nonce)))]], serial: 9 });
  const attestation = cbor({ fmt: "apple-appattest", attStmt: { x5c: [credential, ca.intermediate], receipt: Buffer.from("test receipt") }, authData });
  return { keyID: keyID.toString("base64"), keyBytes: keyID, attestation, device: device.privateKey };
}

/** An assertion by `device` over `clientData`, with `counter`. */
export function assertion(device, clientData, counter, { appID = "DR99P625RR.xyz.onlychan.Dream" } = {}) {
  const counterBytes = Buffer.alloc(4);
  counterBytes.writeUInt32BE(counter);
  const authenticatorData = Buffer.concat([sha256(Buffer.from(appID)), Buffer.from([0]), counterBytes]);
  const nonce = sha256(authenticatorData, sha256(clientData));
  return cbor({ signature: sign("sha256", nonce, { key: device, dsaEncoding: "der" }), authenticatorData });
}

/** What the app signs for a request (attest.ts). */
export const requestData = (method, path, time, body) => Buffer.from(`${method}\n${path}\n${time}\n${sha256(body).toString("hex")}`);
