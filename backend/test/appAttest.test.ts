import { beforeAll, describe, expect, it } from "vitest";
import { AttestationError, verifyAssertion, verifyAttestation } from "../src/appAttest";
import { APPLE_APP_ATTEST_ROOT_PEM } from "../src/appleRoot";
import { parseCertificate, verifySignedBy } from "../src/der";
import { pemToDer, sha256, textEncoder } from "../src/encoding";
import {
  APP_ID,
  createAssertion,
  createAttestation,
  createAuthority,
  createDeviceKey,
  type TestAuthority,
  type TestDevice,
} from "./helpers";

describe("Apple root certificate", () => {
  it("parses and verifies as self-signed", async () => {
    const root = parseCertificate(pemToDer(APPLE_APP_ATTEST_ROOT_PEM));
    expect(root.curve).toBe("1.3.132.0.34"); // P-384
    expect(root.notAfter.getUTCFullYear()).toBe(2045);
    expect(await verifySignedBy(root, root)).toBe(true);
  });
});

describe("verifyAttestation", () => {
  let authority: TestAuthority;
  let device: TestDevice;
  const clientDataHash = new Uint8Array(32).fill(7);

  beforeAll(async () => {
    authority = await createAuthority();
    device = await createDeviceKey();
  });

  const verify = async (attestation: Uint8Array, overrides: { appId?: string; root?: Uint8Array } = {}) =>
    verifyAttestation({
      keyId: device.keyId,
      attestation,
      clientDataHash,
      appId: overrides.appId ?? APP_ID,
      rootCertificate: overrides.root ?? authority.rootDer,
    });

  it("accepts a valid development attestation", async () => {
    const attestation = await createAttestation({ authority, device, clientDataHash });
    const key = await verify(attestation);
    expect(key.environment).toBe("development");
    expect(key.counter).toBe(0);
  });

  it("recognises the production environment", async () => {
    const attestation = await createAttestation({ authority, device, clientDataHash, aaguid: "appattest" });
    expect((await verify(attestation)).environment).toBe("production");
  });

  it("rejects a chain that doesn't lead to the trusted root", async () => {
    const attestation = await createAttestation({ authority, device, clientDataHash });
    const otherRoot = (await createAuthority()).rootDer;
    await expect(verify(attestation, { root: otherRoot })).rejects.toThrow("certificate chain invalid");
  });

  it("rejects the real Apple root for a test chain", async () => {
    const attestation = await createAttestation({ authority, device, clientDataHash });
    await expect(verify(attestation, { root: pemToDer(APPLE_APP_ATTEST_ROOT_PEM) })).rejects.toThrow(
      AttestationError,
    );
  });

  it("rejects an attestation made for a different challenge", async () => {
    const attestation = await createAttestation({ authority, device, clientDataHash: new Uint8Array(32) });
    await expect(verify(attestation)).rejects.toThrow("nonce mismatch");
  });

  it("rejects an attestation for another app", async () => {
    const attestation = await createAttestation({ authority, device, clientDataHash, appId: "OTHER.com.example" });
    await expect(verify(attestation)).rejects.toThrow("app id mismatch");
  });

  it("rejects a key id that doesn't match the certificate", async () => {
    const attestation = await createAttestation({ authority, device, clientDataHash });
    const other = await createDeviceKey();
    await expect(
      verifyAttestation({
        keyId: other.keyId,
        attestation,
        clientDataHash,
        appId: APP_ID,
        rootCertificate: authority.rootDer,
      }),
    ).rejects.toThrow("key id mismatch");
  });

  it("rejects garbage", async () => {
    await expect(verify(new Uint8Array([1, 2, 3]))).rejects.toThrow(AttestationError);
  });
});

describe("verifyAssertion", () => {
  let device: TestDevice;
  let key: Awaited<ReturnType<typeof verifyAttestation>>;
  let clientDataHash: Uint8Array;

  beforeAll(async () => {
    const authority = await createAuthority();
    device = await createDeviceKey();
    clientDataHash = await sha256(textEncoder.encode("challenge"));
    key = await verifyAttestation({
      keyId: device.keyId,
      attestation: await createAttestation({ authority, device, clientDataHash }),
      clientDataHash,
      appId: APP_ID,
      rootCertificate: authority.rootDer,
    });
  });

  it("accepts a signed assertion and returns the new counter", async () => {
    const assertion = await createAssertion({ device, clientDataHash, counter: 1 });
    expect(await verifyAssertion({ assertion, clientDataHash, key, appId: APP_ID })).toBe(1);
  });

  it("rejects a replayed counter", async () => {
    const assertion = await createAssertion({ device, clientDataHash, counter: 3 });
    await expect(
      verifyAssertion({ assertion, clientDataHash, key: { ...key, counter: 3 }, appId: APP_ID }),
    ).rejects.toThrow("counter did not increase");
  });

  it("rejects an assertion over different client data", async () => {
    const assertion = await createAssertion({ device, clientDataHash, counter: 1 });
    await expect(
      verifyAssertion({ assertion, clientDataHash: new Uint8Array(32), key, appId: APP_ID }),
    ).rejects.toThrow("signature invalid");
  });

  it("rejects an assertion signed by another key", async () => {
    const other = await createDeviceKey();
    const assertion = await createAssertion({ device: other, clientDataHash, counter: 1 });
    await expect(verifyAssertion({ assertion, clientDataHash, key, appId: APP_ID })).rejects.toThrow(
      "signature invalid",
    );
  });

  it("rejects an assertion for another app", async () => {
    const assertion = await createAssertion({ device, clientDataHash, counter: 1, appId: "OTHER.com.example" });
    await expect(verifyAssertion({ assertion, clientDataHash, key, appId: APP_ID })).rejects.toThrow(
      "app id mismatch",
    );
  });
});
