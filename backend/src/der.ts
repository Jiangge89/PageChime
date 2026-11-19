/**
 * Just enough DER/X.509 parsing to verify an App Attest certificate chain
 * with WebCrypto: TLV reading, the certificate fields we check, and ECDSA
 * signature conversion.
 */

export interface Tlv {
  tag: number;
  /** Offset of the tag byte. */
  start: number;
  /** Offset of the first value byte. */
  valueStart: number;
  /** Offset just past the value. */
  end: number;
}

export function readTlv(data: Uint8Array, offset: number): Tlv {
  if (offset + 2 > data.length) throw new Error("der: unexpected end");
  const tag = data[offset];
  let length = data[offset + 1];
  let valueStart = offset + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 4) throw new Error("der: unsupported length");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + data[valueStart + i];
    valueStart += count;
  }
  const end = valueStart + length;
  if (end > data.length) throw new Error("der: length out of range");
  return { tag, start: offset, valueStart, end };
}

/** Children of a constructed TLV (SEQUENCE, SET, or context tag). */
export function children(data: Uint8Array, parent: Tlv): Tlv[] {
  const out: Tlv[] = [];
  let offset = parent.valueStart;
  while (offset < parent.end) {
    const child = readTlv(data, offset);
    out.push(child);
    offset = child.end;
  }
  if (offset !== parent.end) throw new Error("der: malformed children");
  return out;
}

export function value(data: Uint8Array, tlv: Tlv): Uint8Array {
  return data.subarray(tlv.valueStart, tlv.end);
}

export function raw(data: Uint8Array, tlv: Tlv): Uint8Array {
  return data.subarray(tlv.start, tlv.end);
}

export function decodeOid(bytes: Uint8Array): string {
  const parts: number[] = [Math.floor(bytes[0] / 40), bytes[0] % 40];
  let current = 0;
  for (let i = 1; i < bytes.length; i++) {
    current = current * 128 + (bytes[i] & 0x7f);
    if (!(bytes[i] & 0x80)) {
      parts.push(current);
      current = 0;
    }
  }
  return parts.join(".");
}

function decodeTime(data: Uint8Array, tlv: Tlv): Date {
  const text = new TextDecoder().decode(value(data, tlv));
  let year: number;
  let rest: string;
  if (tlv.tag === 0x17) {
    const yy = Number(text.slice(0, 2));
    year = yy >= 50 ? 1900 + yy : 2000 + yy;
    rest = text.slice(2);
  } else if (tlv.tag === 0x18) {
    year = Number(text.slice(0, 4));
    rest = text.slice(4);
  } else {
    throw new Error("der: unexpected time tag");
  }
  const [mo, d, h, mi, s] = [0, 2, 4, 6, 8].map((i) => Number(rest.slice(i, i + 2)));
  return new Date(Date.UTC(year, mo - 1, d, h, mi, s));
}

export const OID = {
  ecPublicKey: "1.2.840.10045.2.1",
  p256: "1.2.840.10045.3.1.7",
  p384: "1.3.132.0.34",
  ecdsaSha256: "1.2.840.10045.4.3.2",
  ecdsaSha384: "1.2.840.10045.4.3.3",
  appAttestNonce: "1.2.840.113635.100.8.2",
} as const;

export interface Certificate {
  der: Uint8Array;
  tbs: Uint8Array;
  signatureAlgorithm: string;
  signature: Uint8Array;
  issuer: Uint8Array;
  subject: Uint8Array;
  notBefore: Date;
  notAfter: Date;
  /** SubjectPublicKeyInfo, ready for WebCrypto `importKey("spki", ...)`. */
  spki: Uint8Array;
  curve: string;
  /** Uncompressed EC point (0x04 || x || y). */
  publicKeyPoint: Uint8Array;
  extensions: Map<string, Uint8Array>;
}

export function parseCertificate(der: Uint8Array): Certificate {
  const root = readTlv(der, 0);
  const [tbsTlv, sigAlgTlv, sigTlv] = children(der, root);
  const tbsFields = children(der, tbsTlv);

  // Skip the optional explicit version tag [0].
  let i = tbsFields[0].tag === 0xa0 ? 1 : 0;
  i++; // serial number
  i++; // signature algorithm (repeated in the outer certificate)
  const issuerTlv = tbsFields[i++];
  const [notBeforeTlv, notAfterTlv] = children(der, tbsFields[i++]);
  const subjectTlv = tbsFields[i++];
  const spkiTlv = tbsFields[i++];

  const extensions = new Map<string, Uint8Array>();
  for (const field of tbsFields.slice(i)) {
    if (field.tag !== 0xa3) continue;
    const [extensionList] = children(der, field);
    for (const extension of children(der, extensionList)) {
      const parts = children(der, extension);
      const oid = decodeOid(value(der, parts[0]));
      extensions.set(oid, value(der, parts[parts.length - 1]));
    }
  }

  const [algorithmTlv, pointTlv] = children(der, spkiTlv);
  const algorithmParts = children(der, algorithmTlv);
  if (decodeOid(value(der, algorithmParts[0])) !== OID.ecPublicKey) {
    throw new Error("der: certificate key is not EC");
  }
  const curve = decodeOid(value(der, algorithmParts[1]));
  // BIT STRING: first byte is the number of unused bits (always 0 here).
  const publicKeyPoint = value(der, pointTlv).subarray(1);

  const sigAlgOid = decodeOid(value(der, children(der, sigAlgTlv)[0]));

  return {
    der,
    tbs: raw(der, tbsTlv),
    signatureAlgorithm: sigAlgOid,
    signature: value(der, sigTlv).subarray(1),
    issuer: raw(der, issuerTlv),
    subject: raw(der, subjectTlv),
    notBefore: decodeTime(der, notBeforeTlv),
    notAfter: decodeTime(der, notAfterTlv),
    spki: raw(der, spkiTlv),
    curve,
    publicKeyPoint,
    extensions,
  };
}

export function curveName(oid: string): "P-256" | "P-384" {
  if (oid === OID.p256) return "P-256";
  if (oid === OID.p384) return "P-384";
  throw new Error(`der: unsupported curve ${oid}`);
}

/** Converts an ASN.1 DER ECDSA signature to the raw r||s form WebCrypto expects. */
export function derSignatureToRaw(signature: Uint8Array, size: number): Uint8Array {
  const seq = readTlv(signature, 0);
  const [r, s] = children(signature, seq);
  const out = new Uint8Array(size * 2);
  for (const [index, part] of [r, s].entries()) {
    let bytes = value(signature, part);
    while (bytes.length > size && bytes[0] === 0) bytes = bytes.subarray(1);
    if (bytes.length > size) throw new Error("der: signature integer too large");
    out.set(bytes, index * size + (size - bytes.length));
  }
  return out;
}

export async function importCertificateKey(cert: Certificate): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "spki",
    cert.spki,
    { name: "ECDSA", namedCurve: curveName(cert.curve) },
    false,
    ["verify"],
  );
}

/** Verifies that `cert` was signed by `issuer` and that the names chain. */
export async function verifySignedBy(cert: Certificate, issuer: Certificate): Promise<boolean> {
  if (!sameBytes(cert.issuer, issuer.subject)) return false;
  const hash =
    cert.signatureAlgorithm === OID.ecdsaSha256
      ? "SHA-256"
      : cert.signatureAlgorithm === OID.ecdsaSha384
        ? "SHA-384"
        : null;
  if (!hash) return false;
  const size = curveName(issuer.curve) === "P-256" ? 32 : 48;
  const key = await importCertificateKey(issuer);
  return crypto.subtle.verify(
    { name: "ECDSA", hash },
    key,
    derSignatureToRaw(cert.signature, size),
    cert.tbs,
  );
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((byte, i) => byte === b[i]);
}
