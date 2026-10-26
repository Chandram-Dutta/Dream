// Just enough CBOR (RFC 8949) to read App Attest's attestation and assertion objects
// (attest.ts): maps, arrays, byte and text strings, integers and simple values. Nothing
// indefinite-length, no tags, and bounded in depth and size, since what's read came from outside.

export type CBOR = number | bigint | string | Uint8Array | boolean | null | undefined | CBOR[] | Map<CBOR, CBOR>;

export class CBORError extends Error {}

/** Decodes one item at `offset`, returning it and where it ended. */
export function decode(bytes: Uint8Array, offset = 0, depth = 0): { value: CBOR; end: number } {
  if (depth > 16) throw new CBORError("too deep");
  if (offset >= bytes.length) throw new CBORError("short");
  const first = bytes[offset];
  const major = first >> 5;
  const info = first & 0x1f;
  let position = offset + 1;
  const need = (count: number) => {
    if (position + count > bytes.length) throw new CBORError("short");
  };
  let argument: number | bigint;
  if (info < 24) {
    argument = info;
  } else if (info >= 24 && info <= 27) {
    const size = 1 << (info - 24);
    need(size);
    let value = 0n;
    for (let i = 0; i < size; i++) value = (value << 8n) | BigInt(bytes[position + i]);
    position += size;
    argument = value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value) : value;
  } else {
    throw new CBORError("indefinite lengths aren't read");
  }
  const length = (): number => {
    if (typeof argument !== "number" || argument > bytes.length) throw new CBORError("length");
    return argument;
  };
  switch (major) {
    case 0:
      return { value: argument, end: position };
    case 1:
      return { value: typeof argument === "number" ? -1 - argument : -1n - argument, end: position };
    case 2: {
      const size = length();
      need(size);
      return { value: bytes.subarray(position, position + size), end: position + size };
    }
    case 3: {
      const size = length();
      need(size);
      return { value: new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes.subarray(position, position + size)), end: position + size };
    }
    case 4: {
      const count = length();
      const items: CBOR[] = [];
      for (let i = 0; i < count; i++) {
        const item = decode(bytes, position, depth + 1);
        items.push(item.value);
        position = item.end;
      }
      return { value: items, end: position };
    }
    case 5: {
      const count = length();
      const map = new Map<CBOR, CBOR>();
      for (let i = 0; i < count; i++) {
        const key = decode(bytes, position, depth + 1);
        const item = decode(bytes, key.end, depth + 1);
        map.set(key.value, item.value);
        position = item.end;
      }
      return { value: map, end: position };
    }
    case 7:
      if (info === 20) return { value: false, end: position };
      if (info === 21) return { value: true, end: position };
      if (info === 22) return { value: null, end: position };
      if (info === 23) return { value: undefined, end: position };
      throw new CBORError("floats and other simple values aren't read");
    default:
      throw new CBORError("tags aren't read");
  }
}

/** A whole buffer that's exactly one item. */
export function decodeAll(bytes: Uint8Array): CBOR {
  const { value, end } = decode(bytes);
  if (end !== bytes.length) throw new CBORError("trailing bytes");
  return value;
}
