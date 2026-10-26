// Just enough DER and X.509 to check certificate chains that Apple signs: the App Store's signed
// transactions and notifications (appstore.ts), and App Attest's attestations (attest.ts). Both
// are elliptic-curve chains (P-256 and P-384), checked with the runtime's Web Crypto. Nothing
// here fetches anything: roots are pinned in code, and revocation isn't checked (README.md).

export interface Node {
  /** The tag byte, as written: 0x30 is a SEQUENCE, 0xa3 is [3] constructed. */
  tag: number;
  /** The whole element, header included: what a signature covers. */
  bytes: Uint8Array;
  /** The contents, without the header. */
  value: Uint8Array;
}

export class DERError extends Error {}

/** One DER element at `offset`. Indefinite lengths aren't DER, so they're refused. */
export function read(bytes: Uint8Array, offset = 0): Node {
  if (offset + 2 > bytes.length) throw new DERError("short");
  const tag = bytes[offset];
  if ((tag & 0x1f) === 0x1f) throw new DERError("long tags");
  let length = bytes[offset + 1];
  let header = 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 4) throw new DERError("length");
    if (offset + 2 + count > bytes.length) throw new DERError("short");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[offset + 2 + i];
    header += count;
  }
  const end = offset + header + length;
  if (end > bytes.length) throw new DERError("short");
  return { tag, bytes: bytes.subarray(offset, end), value: bytes.subarray(offset + header, end) };
}

/** The elements inside a constructed one, in order. */
export function children(node: Node): Node[] {
  const list: Node[] = [];
  let offset = 0;
  while (offset < node.value.length) {
    const child = read(node.value, offset);
    list.push(child);
    offset += child.bytes.length;
  }
  return list;
}

export function oid(node: Node): string {
  if (node.tag !== 0x06) throw new DERError("not an OID");
  const bytes = node.value;
  const parts: number[] = [];
  let value = 0;
  for (const byte of bytes) {
    value = value * 128 + (byte & 0x7f);
    if (!(byte & 0x80)) {
      if (!parts.length) parts.push(value < 80 ? Math.floor(value / 40) : 2, value < 80 ? value % 40 : value - 80);
      else parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

/** UTCTime or GeneralizedTime, as milliseconds since 1970. */
function time(node: Node): number {
  const text = new TextDecoder().decode(node.value);
  const match = node.tag === 0x17 ? /^(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)Z$/.exec(text) : node.tag === 0x18 ? /^(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)Z$/.exec(text) : null;
  if (!match) throw new DERError("time");
  let year = Number(match[1]);
  if (node.tag === 0x17) year += year >= 50 ? 1900 : 2000;
  return Date.UTC(year, Number(match[2]) - 1, Number(match[3]), Number(match[4]), Number(match[5]), Number(match[6]));
}

export const OID = {
  ecPublicKey: "1.2.840.10045.2.1",
  p256: "1.2.840.10045.3.1.7",
  p384: "1.3.132.0.34",
  ecdsaSHA256: "1.2.840.10045.4.3.2",
  ecdsaSHA384: "1.2.840.10045.4.3.3",
  basicConstraints: "2.5.29.19",
} as const;

export interface Certificate {
  /** The whole certificate, as sent. */
  der: Uint8Array;
  /** What the issuer signed. */
  tbs: Uint8Array;
  signatureAlgorithm: string;
  /** The signature as DER: SEQUENCE { r, s }. */
  signature: Uint8Array;
  issuer: Uint8Array;
  subject: Uint8Array;
  notBefore: number;
  notAfter: number;
  /** SubjectPublicKeyInfo, as Web Crypto imports it. */
  spki: Uint8Array;
  curve: "P-256" | "P-384";
  /** The public key as an uncompressed point (0x04 ‖ x ‖ y). */
  point: Uint8Array;
  isCA: boolean;
  /** Extension contents (the inside of extnValue's OCTET STRING), by OID. */
  extensions: Map<string, Uint8Array>;
}

/** Parses a certificate. Only elliptic-curve keys on P-256 and P-384 are accepted. */
export function certificate(der: Uint8Array): Certificate {
  const outer = read(der);
  if (outer.tag !== 0x30 || outer.bytes.length !== der.length) throw new DERError("certificate");
  const [tbsNode, algorithmNode, signatureNode] = children(outer);
  if (!tbsNode || tbsNode.tag !== 0x30 || !algorithmNode || !signatureNode || signatureNode.tag !== 0x03) throw new DERError("certificate");
  const tbs = children(tbsNode);
  let index = tbs[0]?.tag === 0xa0 ? 1 : 0; // version
  index += 1; // serial number
  index += 1; // signature algorithm, again
  const issuer = tbs[index++];
  const validity = tbs[index++];
  const subject = tbs[index++];
  const spki = tbs[index++];
  if (!issuer || !validity || !subject || !spki) throw new DERError("certificate");
  const [notBefore, notAfter] = children(validity);
  const [keyAlgorithm, keyBits] = children(spki);
  const [keyType, curveOID] = children(keyAlgorithm);
  if (oid(keyType) !== OID.ecPublicKey || !curveOID) throw new DERError("key");
  const curveName = oid(curveOID);
  const curve = curveName === OID.p256 ? "P-256" : curveName === OID.p384 ? "P-384" : null;
  if (!curve || keyBits.tag !== 0x03 || keyBits.value[0] !== 0) throw new DERError("key");

  const extensions = new Map<string, Uint8Array>();
  let isCA = false;
  for (const node of tbs.slice(index)) {
    if (node.tag !== 0xa3) continue;
    const [list] = children(node);
    for (const extension of children(list)) {
      const parts = children(extension);
      const id = oid(parts[0]);
      const value = parts[parts.length - 1];
      if (value.tag !== 0x04) throw new DERError("extension");
      extensions.set(id, value.value);
      if (id === OID.basicConstraints) {
        const [flag] = children(read(value.value));
        isCA = flag?.tag === 0x01 && flag.value[0] !== 0;
      }
    }
  }
  const [algorithm] = children(algorithmNode);
  if (signatureNode.value[0] !== 0) throw new DERError("signature");
  return {
    der,
    tbs: tbsNode.bytes,
    signatureAlgorithm: oid(algorithm),
    signature: signatureNode.value.subarray(1),
    issuer: issuer.bytes,
    subject: subject.bytes,
    notBefore: time(notBefore),
    notAfter: time(notAfter),
    spki: spki.bytes,
    curve,
    point: keyBits.value.subarray(1),
    isCA,
    extensions,
  };
}

export function fromBase64(text: string): Uint8Array {
  const clean = text.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/");
  const padded = clean + "=".repeat((4 - (clean.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}

/** A DER signature, SEQUENCE { r, s }, as the fixed-size r ‖ s Web Crypto expects. */
export function rawSignature(der: Uint8Array, curve: "P-256" | "P-384"): Uint8Array {
  const size = curve === "P-256" ? 32 : 48;
  const [r, s] = children(read(der));
  if (r?.tag !== 0x02 || s?.tag !== 0x02) throw new DERError("signature");
  const raw = new Uint8Array(size * 2);
  for (const [index, integer] of [r, s].entries()) {
    let bytes = integer.value;
    while (bytes.length > 1 && bytes[0] === 0) bytes = bytes.subarray(1);
    if (bytes.length > size) throw new DERError("signature");
    raw.set(bytes, index * size + size - bytes.length);
  }
  return raw;
}

// A copy of exactly these bytes: a view's .buffer can hold far more (Node's Buffer pool, say).
const buffer = (bytes: Uint8Array): ArrayBuffer => new Uint8Array(bytes).buffer as ArrayBuffer;

export async function importKey(spki: Uint8Array, curve: "P-256" | "P-384"): Promise<CryptoKey> {
  return crypto.subtle.importKey("spki", buffer(spki), { name: "ECDSA", namedCurve: curve }, false, ["verify"]);
}

/** Whether `signature` (DER, or raw r ‖ s) by `key` covers `data`, hashed with `hash`. */
export async function verifySignature(key: CryptoKey, curve: "P-256" | "P-384", hash: "SHA-256" | "SHA-384", signature: Uint8Array, data: Uint8Array, raw = false): Promise<boolean> {
  try {
    const bytes = raw ? signature : rawSignature(signature, curve);
    return await crypto.subtle.verify({ name: "ECDSA", hash }, key, buffer(bytes), buffer(data));
  } catch {
    return false;
  }
}

/** Whether `issuer` signed `subject`. */
async function signed(subject: Certificate, issuer: Certificate): Promise<boolean> {
  if (!equal(subject.issuer, issuer.subject)) return false;
  const hash = subject.signatureAlgorithm === OID.ecdsaSHA256 ? "SHA-256" : subject.signatureAlgorithm === OID.ecdsaSHA384 ? "SHA-384" : null;
  if (!hash) return false;
  return verifySignature(await importKey(issuer.spki, issuer.curve), issuer.curve, hash, subject.signature, subject.tbs);
}

/** How far clocks may disagree, as Apple's own library allows. */
const SKEW = 60_000;

const current = (certificate: Certificate, at: number) => certificate.notBefore - SKEW <= at && at <= certificate.notAfter + SKEW;

export class ChainError extends Error {}

/** Checks that `leaf` was signed by `intermediate`, a CA, which one of `roots` signed, and that
 * all three were valid at `at`. The root the sender included, if any, is never trusted itself. */
export async function verifyChain(leaf: Certificate, intermediate: Certificate, roots: Certificate[], at: number): Promise<void> {
  let root: Certificate | undefined;
  for (const candidate of roots) {
    if (await signed(intermediate, candidate)) {
      root = candidate;
      break;
    }
  }
  if (!root) throw new ChainError("not signed by a trusted root");
  if (!intermediate.isCA) throw new ChainError("the intermediate isn't a CA");
  if (!(await signed(leaf, intermediate))) throw new ChainError("the leaf isn't signed by the intermediate");
  if (![leaf, intermediate, root].every((certificate) => current(certificate, at))) throw new ChainError("a certificate wasn't valid then");
}

/** The first OCTET STRING inside a DER structure, depth first. App Attest's nonce extension is
 * SEQUENCE { [1] { OCTET STRING } }. */
export function firstOctetString(bytes: Uint8Array): Uint8Array | null {
  const node = read(bytes);
  if (node.tag === 0x04) return node.value;
  if (!(node.tag & 0x20)) return null;
  for (const child of children(node)) {
    const found = firstOctetString(child.bytes);
    if (found) return found;
  }
  return null;
}

export async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", buffer(bytes)));
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export function hex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
