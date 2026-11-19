/**
 * Minimal CBOR decoder covering what App Attest uses: unsigned/negative
 * integers, byte and text strings, arrays, maps, and simple values.
 * Indefinite lengths, tags and floats are rejected.
 */
export type CborValue =
  | number
  | string
  | boolean
  | null
  | undefined
  | Uint8Array
  | CborValue[]
  | Map<CborValue, CborValue>;

export function decodeCbor(data: Uint8Array): CborValue {
  const reader = { data, offset: 0 };
  const value = readItem(reader, 0);
  if (reader.offset !== data.length) throw new Error("cbor: trailing bytes");
  return value;
}

/** Decodes a CBOR map with text keys into a plain object. */
export function decodeCborMap(data: Uint8Array): Record<string, CborValue> {
  const value = decodeCbor(data);
  if (!(value instanceof Map)) throw new Error("cbor: expected map");
  const out: Record<string, CborValue> = {};
  for (const [key, entry] of value) {
    if (typeof key === "string") out[key] = entry;
  }
  return out;
}

interface Reader {
  data: Uint8Array;
  offset: number;
}

function readByte(r: Reader): number {
  if (r.offset >= r.data.length) throw new Error("cbor: unexpected end");
  return r.data[r.offset++];
}

function readLength(r: Reader, info: number): number {
  if (info < 24) return info;
  const size = info === 24 ? 1 : info === 25 ? 2 : info === 26 ? 4 : info === 27 ? 8 : 0;
  if (size === 0) throw new Error("cbor: unsupported length encoding");
  let value = 0;
  for (let i = 0; i < size; i++) value = value * 256 + readByte(r);
  if (!Number.isSafeInteger(value)) throw new Error("cbor: length too large");
  return value;
}

function readBytes(r: Reader, length: number): Uint8Array {
  if (r.offset + length > r.data.length) throw new Error("cbor: unexpected end");
  const out = r.data.subarray(r.offset, r.offset + length);
  r.offset += length;
  return out;
}

function readItem(r: Reader, depth: number): CborValue {
  if (depth > 16) throw new Error("cbor: nesting too deep");
  const initial = readByte(r);
  const major = initial >> 5;
  const info = initial & 0x1f;

  switch (major) {
    case 0:
      return readLength(r, info);
    case 1:
      return -1 - readLength(r, info);
    case 2:
      return readBytes(r, readLength(r, info));
    case 3:
      return new TextDecoder().decode(readBytes(r, readLength(r, info)));
    case 4: {
      const length = readLength(r, info);
      const items: CborValue[] = [];
      for (let i = 0; i < length; i++) items.push(readItem(r, depth + 1));
      return items;
    }
    case 5: {
      const length = readLength(r, info);
      const map = new Map<CborValue, CborValue>();
      for (let i = 0; i < length; i++) {
        const key = readItem(r, depth + 1);
        map.set(key, readItem(r, depth + 1));
      }
      return map;
    }
    case 7:
      if (info === 20) return false;
      if (info === 21) return true;
      if (info === 22) return null;
      if (info === 23) return undefined;
      throw new Error("cbor: unsupported simple value");
    default:
      throw new Error("cbor: unsupported major type");
  }
}
