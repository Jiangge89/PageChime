/**
 * Server-side App Attest verification, following Apple's "Validating Apps
 * That Connect to Your Server":
 * https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
 */
import { decodeCborMap } from "./cbor";
import { OID, children, parseCertificate, readTlv, value, verifySignedBy, derSignatureToRaw } from "./der";
import { concat, equalBytes, fromBase64, sha256, textEncoder, toBase64 } from "./encoding";

export type AttestEnvironment = "development" | "production";

export interface AttestedKey {
  /** Uncompressed P-256 point, base64. */
  publicKey: string;
  counter: number;
  environment: AttestEnvironment;
  createdAt: number;
}

export class AttestationError extends Error {}

const AAGUID_DEVELOPMENT = textEncoder.encode("appattestdevelop");
const AAGUID_PRODUCTION = concat(textEncoder.encode("appattest"), new Uint8Array(7));

interface AuthenticatorData {
  rpIdHash: Uint8Array;
  counter: number;
  aaguid?: Uint8Array;
  credentialId?: Uint8Array;
}

function parseAuthenticatorData(data: Uint8Array, withCredential: boolean): AuthenticatorData {
  if (data.length < 37) throw new AttestationError("authenticator data too short");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const parsed: AuthenticatorData = {
    rpIdHash: data.subarray(0, 32),
    counter: view.getUint32(33),
  };
  if (withCredential) {
    if (data.length < 55) throw new AttestationError("attested credential data missing");
    const idLength = view.getUint16(53);
    if (data.length < 55 + idLength) throw new AttestationError("credential id truncated");
    parsed.aaguid = data.subarray(37, 53);
    parsed.credentialId = data.subarray(55, 55 + idLength);
  }
  return parsed;
}

function bytesField(value: unknown, name: string): Uint8Array {
  if (!(value instanceof Uint8Array)) throw new AttestationError(`missing ${name}`);
  return value;
}

/** Reads the nonce from the App Attest certificate extension. */
function extensionNonce(extension: Uint8Array): Uint8Array {
  // SEQUENCE { [1] EXPLICIT OCTET STRING nonce }
  const sequence = readTlv(extension, 0);
  const tagged = children(extension, sequence).find((tlv) => tlv.tag === 0xa1);
  if (!tagged) throw new AttestationError("nonce extension malformed");
  const [octets] = children(extension, tagged);
  return value(extension, octets);
}

export async function verifyAttestation(params: {
  keyId: string;
  attestation: Uint8Array;
  clientDataHash: Uint8Array;
  appId: string;
  rootCertificate: Uint8Array;
  now?: Date;
}): Promise<AttestedKey> {
  const now = params.now ?? new Date();
  let object;
  try {
    object = decodeCborMap(params.attestation);
  } catch {
    throw new AttestationError("attestation is not valid CBOR");
  }
  if (object.fmt !== "apple-appattest") throw new AttestationError("unexpected format");

  const statement = object.attStmt;
  if (!(statement instanceof Map)) throw new AttestationError("missing attStmt");
  const x5c = statement.get("x5c");
  if (!Array.isArray(x5c) || x5c.length < 2) throw new AttestationError("missing certificate chain");
  const authData = bytesField(object.authData, "authData");

  // 1. Certificate chain: credential cert <- intermediate <- Apple root.
  let credential, intermediate, root;
  try {
    credential = parseCertificate(bytesField(x5c[0], "credential certificate"));
    intermediate = parseCertificate(bytesField(x5c[1], "intermediate certificate"));
    root = parseCertificate(params.rootCertificate);
  } catch (error) {
    if (error instanceof AttestationError) throw error;
    throw new AttestationError("certificate could not be parsed");
  }
  for (const cert of [credential, intermediate]) {
    if (now < cert.notBefore || now > cert.notAfter) throw new AttestationError("certificate expired");
  }
  if (!(await verifySignedBy(intermediate, root)) || !(await verifySignedBy(credential, intermediate))) {
    throw new AttestationError("certificate chain invalid");
  }

  // 2-4. The nonce in the credential certificate matches authData + challenge.
  const nonce = await sha256(concat(authData, params.clientDataHash));
  const extension = credential.extensions.get(OID.appAttestNonce);
  if (!extension || !equalBytes(extensionNonce(extension), nonce)) {
    throw new AttestationError("nonce mismatch");
  }

  // 5. The key identifier is the hash of the credential public key.
  const keyHash = await sha256(credential.publicKeyPoint);
  if (!equalBytes(keyHash, fromBase64(params.keyId))) throw new AttestationError("key id mismatch");

  // 6-9. Authenticator data belongs to this app and a fresh key.
  const parsed = parseAuthenticatorData(authData, true);
  if (!equalBytes(parsed.rpIdHash, await sha256(textEncoder.encode(params.appId)))) {
    throw new AttestationError("app id mismatch");
  }
  if (parsed.counter !== 0) throw new AttestationError("counter must be zero");
  let environment: AttestEnvironment;
  if (equalBytes(parsed.aaguid!, AAGUID_DEVELOPMENT)) environment = "development";
  else if (equalBytes(parsed.aaguid!, AAGUID_PRODUCTION)) environment = "production";
  else throw new AttestationError("unknown aaguid");
  if (!equalBytes(parsed.credentialId!, keyHash)) throw new AttestationError("credential id mismatch");

  return {
    publicKey: toBase64(credential.publicKeyPoint),
    counter: 0,
    environment,
    createdAt: now.getTime(),
  };
}

/** Verifies an assertion and returns the new counter to store. */
export async function verifyAssertion(params: {
  assertion: Uint8Array;
  clientDataHash: Uint8Array;
  key: AttestedKey;
  appId: string;
}): Promise<number> {
  let object;
  try {
    object = decodeCborMap(params.assertion);
  } catch {
    throw new AttestationError("assertion is not valid CBOR");
  }
  const signature = bytesField(object.signature, "signature");
  const authenticatorData = bytesField(object.authenticatorData, "authenticatorData");

  const nonce = await sha256(concat(authenticatorData, params.clientDataHash));
  const publicKey = await crypto.subtle.importKey(
    "raw",
    fromBase64(params.key.publicKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  let valid = false;
  try {
    valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      derSignatureToRaw(signature, 32),
      nonce,
    );
  } catch {
    valid = false;
  }
  if (!valid) throw new AttestationError("signature invalid");

  const parsed = parseAuthenticatorData(authenticatorData, false);
  if (!equalBytes(parsed.rpIdHash, await sha256(textEncoder.encode(params.appId)))) {
    throw new AttestationError("app id mismatch");
  }
  if (parsed.counter <= params.key.counter) throw new AttestationError("counter did not increase");
  return parsed.counter;
}
