/**
 * Builds App Attest objects with a test certificate authority, mirroring the
 * structure Apple's servers produce, so the full verification path can run
 * without a device.
 */
import * as x509 from "@peculiar/x509";
import { Encoder } from "cbor-x";

// Plain CBOR as Apple produces it: byte strings without typed-array tags.
const cbor = new Encoder({ tagUint8Array: false, useRecords: false, mapsAsObjects: true });
const encode = (value: unknown) => cbor.encode(value);
import { concat, sha256, textEncoder, toBase64 } from "../src/encoding";
import type { Env, KeyStore, RateLimiter } from "../src/index";

x509.cryptoProvider.set(crypto);

export const APP_ID = "TEAM123456.com.pagechime.app";

const P384 = { name: "ECDSA", namedCurve: "P-384" } as const;
const P256 = { name: "ECDSA", namedCurve: "P-256" } as const;

export interface TestAuthority {
  rootDer: Uint8Array;
  intermediate: x509.X509Certificate;
  intermediateKeys: CryptoKeyPair;
}

export async function createAuthority(): Promise<TestAuthority> {
  const rootKeys = (await crypto.subtle.generateKey(P384, true, ["sign", "verify"])) as CryptoKeyPair;
  const root = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01",
    name: "CN=Test App Attestation Root CA",
    notBefore: new Date("2020-01-01"),
    notAfter: new Date("2045-01-01"),
    signingAlgorithm: { name: "ECDSA", hash: "SHA-384" },
    keys: rootKeys,
    extensions: [new x509.BasicConstraintsExtension(true, undefined, true)],
  });
  const intermediateKeys = (await crypto.subtle.generateKey(P384, true, ["sign", "verify"])) as CryptoKeyPair;
  const intermediate = await x509.X509CertificateGenerator.create({
    serialNumber: "02",
    subject: "CN=Test App Attestation CA 1",
    issuer: root.subject,
    notBefore: new Date("2020-01-01"),
    notAfter: new Date("2040-01-01"),
    signingAlgorithm: { name: "ECDSA", hash: "SHA-384" },
    publicKey: intermediateKeys.publicKey,
    signingKey: rootKeys.privateKey,
    extensions: [new x509.BasicConstraintsExtension(true, 0, true)],
  });
  return { rootDer: new Uint8Array(root.rawData), intermediate, intermediateKeys };
}

export interface TestDevice {
  keyId: string;
  keys: CryptoKeyPair;
  publicPoint: Uint8Array;
}

export async function createDeviceKey(): Promise<TestDevice> {
  const keys = (await crypto.subtle.generateKey(P256, true, ["sign", "verify"])) as CryptoKeyPair;
  const publicPoint = new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
  return { keys, publicPoint, keyId: toBase64(await sha256(publicPoint)) };
}

export function authenticatorData(params: {
  appId: string;
  rpIdHash?: Uint8Array;
  counter: number;
  aaguid?: string;
  credentialId?: Uint8Array;
}): Promise<Uint8Array> {
  return (async () => {
    const rpIdHash = params.rpIdHash ?? (await sha256(textEncoder.encode(params.appId)));
    const counter = new Uint8Array(4);
    new DataView(counter.buffer).setUint32(0, params.counter);
    const parts = [rpIdHash, new Uint8Array([0x40]), counter];
    if (params.credentialId) {
      const aaguid = new Uint8Array(16);
      aaguid.set(textEncoder.encode(params.aaguid ?? "appattestdevelop").subarray(0, 16));
      const length = new Uint8Array(2);
      new DataView(length.buffer).setUint16(0, params.credentialId.length);
      parts.push(aaguid, length, params.credentialId);
    }
    return concat(...parts);
  })();
}

function nonceExtension(nonce: Uint8Array): x509.Extension {
  // SEQUENCE { [1] { OCTET STRING nonce } }
  const value = concat(new Uint8Array([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]), nonce);
  return new x509.Extension("1.2.840.113635.100.8.2", false, value);
}

export async function createAttestation(params: {
  authority: TestAuthority;
  device: TestDevice;
  clientDataHash: Uint8Array;
  appId?: string;
  aaguid?: string;
  /** Overrides the nonce placed in the certificate. */
  nonce?: Uint8Array;
}): Promise<Uint8Array> {
  const { authority, device } = params;
  const authData = await authenticatorData({
    appId: params.appId ?? APP_ID,
    counter: 0,
    aaguid: params.aaguid,
    credentialId: await sha256(device.publicPoint),
  });
  const nonce = params.nonce ?? (await sha256(concat(authData, params.clientDataHash)));
  const credential = await x509.X509CertificateGenerator.create({
    serialNumber: "03",
    subject: "CN=test-credential",
    issuer: authority.intermediate.subject,
    notBefore: new Date(Date.now() - 60_000),
    notAfter: new Date(Date.now() + 3 * 86_400_000),
    signingAlgorithm: { name: "ECDSA", hash: "SHA-256" },
    publicKey: device.keys.publicKey,
    signingKey: authority.intermediateKeys.privateKey,
    extensions: [nonceExtension(nonce)],
  });
  return new Uint8Array(
    encode({
      fmt: "apple-appattest",
      attStmt: {
        x5c: [new Uint8Array(credential.rawData), new Uint8Array(authority.intermediate.rawData)],
        receipt: new Uint8Array([1, 2, 3]),
      },
      authData,
    }),
  );
}

/** Encodes a raw r||s signature as ASN.1 DER, the way Apple returns it. */
export function rawSignatureToDer(raw: Uint8Array): Uint8Array {
  const half = raw.length / 2;
  const integer = (bytes: Uint8Array) => {
    let start = 0;
    while (start < bytes.length - 1 && bytes[start] === 0) start++;
    let trimmed = bytes.subarray(start);
    if (trimmed[0] & 0x80) trimmed = concat(new Uint8Array([0]), trimmed);
    return concat(new Uint8Array([0x02, trimmed.length]), trimmed);
  };
  const body = concat(integer(raw.subarray(0, half)), integer(raw.subarray(half)));
  return concat(new Uint8Array([0x30, body.length]), body);
}

export async function createAssertion(params: {
  device: TestDevice;
  clientDataHash: Uint8Array;
  counter: number;
  appId?: string;
}): Promise<Uint8Array> {
  const authData = await authenticatorData({ appId: params.appId ?? APP_ID, counter: params.counter });
  const nonce = await sha256(concat(authData, params.clientDataHash));
  const signature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, params.device.keys.privateKey, nonce),
  );
  return new Uint8Array(encode({ signature: rawSignatureToDer(signature), authenticatorData: authData }));
}

export class MemoryKeyStore implements KeyStore {
  readonly entries = new Map<string, string>();
  async get(key: string) {
    return this.entries.get(key) ?? null;
  }
  async put(key: string, value: string) {
    this.entries.set(key, value);
  }
}

export class CountingLimiter implements RateLimiter {
  private counts = new Map<string, number>();
  constructor(private readonly max = Infinity) {}
  async limit({ key }: { key: string }) {
    const count = (this.counts.get(key) ?? 0) + 1;
    this.counts.set(key, count);
    return { success: count <= this.max };
  }
}

export function testEnv(overrides: Partial<Env> = {}): Env {
  return {
    OPENAI_API_KEY: "test-openai-key",
    TOKEN_SECRET: "test-token-secret",
    APP_ID,
    OPENAI_MODEL: "gpt-4o-mini",
    ALLOW_DEV_SESSIONS: "false",
    DEVICE_KEYS: new MemoryKeyStore(),
    DEVICE_LIMITER: new CountingLimiter(),
    AUTH_LIMITER: new CountingLimiter(),
    ...overrides,
  };
}
