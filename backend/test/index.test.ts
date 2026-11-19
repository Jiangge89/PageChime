import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { fromBase64, sha256, textEncoder, toBase64 } from "../src/encoding";
import { handleRequest, type Env } from "../src/index";
import {
  CountingLimiter,
  createAssertion,
  createAttestation,
  createAuthority,
  createDeviceKey,
  MemoryKeyStore,
  testEnv,
  type TestAuthority,
} from "./helpers";

let authority: TestAuthority;

beforeAll(async () => {
  authority = await createAuthority();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function post(path: string, body?: unknown, headers: Record<string, string> = {}): Request {
  return new Request(`https://api.test${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function call(env: Env, request: Request) {
  const response = await handleRequest(request, env, { rootCertificate: authority.rootDer });
  return { status: response.status, body: (await response.json()) as Record<string, any> };
}

async function challenge(env: Env): Promise<string> {
  return (await call(env, post("/v1/challenge"))).body.challenge;
}

async function attestNewDevice(env: Env) {
  const device = await createDeviceKey();
  const value = await challenge(env);
  const clientDataHash = await sha256(textEncoder.encode(value));
  const attestation = await createAttestation({ authority, device, clientDataHash });
  const result = await call(
    env,
    post("/v1/attest", { keyId: device.keyId, attestation: toBase64(attestation), challenge: value }),
  );
  return { device, ...result };
}

function stubOpenAI(content: unknown) {
  const fetchMock = vi.fn(
    async () => new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(content) } }] })),
  );
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

describe("attest → analyze", () => {
  it("issues a session for a valid attestation and serves analysis with it", async () => {
    const env = testEnv();
    const { status, body, device } = await attestNewDevice(env);
    expect(status).toBe(200);
    expect(body.expiresIn).toBe(3600);
    expect((env.DEVICE_KEYS as MemoryKeyStore).entries.has(`key:${device.keyId}`)).toBe(true);

    const fetchMock = stubOpenAI({ sounds: [{ id: "wind", trigger: "wind" }], ambience: ["wind"] });
    const analysis = await call(
      env,
      post("/v1/analyze", { text: "the wind blew", context: "" }, { Authorization: `Bearer ${body.token}` }),
    );
    expect(analysis.status).toBe(200);
    expect(analysis.body).toEqual({ sounds: [{ id: "wind", trigger: "wind" }], ambience: ["wind"] });
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("rejects an attestation with an expired or forged challenge", async () => {
    const env = testEnv();
    const device = await createDeviceKey();
    const attestation = await createAttestation({ authority, device, clientDataHash: new Uint8Array(32) });
    const result = await call(
      env,
      post("/v1/attest", { keyId: device.keyId, attestation: toBase64(attestation), challenge: "1.2.3" }),
    );
    expect(result.status).toBe(401);
  });

  it("refuses to attest the same key twice", async () => {
    const env = testEnv();
    const { device } = await attestNewDevice(env);
    const value = await challenge(env);
    const attestation = await createAttestation({
      authority,
      device,
      clientDataHash: await sha256(textEncoder.encode(value)),
    });
    const again = await call(
      env,
      post("/v1/attest", { keyId: device.keyId, attestation: toBase64(attestation), challenge: value }),
    );
    expect(again.status).toBe(409);
  });
});

describe("assert", () => {
  it("issues a new session for a known key and stores the counter", async () => {
    const env = testEnv();
    const { device } = await attestNewDevice(env);
    const value = await challenge(env);
    const assertion = await createAssertion({
      device,
      clientDataHash: await sha256(textEncoder.encode(value)),
      counter: 1,
    });
    const result = await call(
      env,
      post("/v1/assert", { keyId: device.keyId, assertion: toBase64(assertion), challenge: value }),
    );
    expect(result.status).toBe(200);
    expect(typeof result.body.token).toBe("string");

    const stored = JSON.parse((env.DEVICE_KEYS as MemoryKeyStore).entries.get(`key:${device.keyId}`)!);
    expect(stored.counter).toBe(1);

    // Replaying the same assertion fails because the counter didn't increase.
    const replay = await call(
      env,
      post("/v1/assert", { keyId: device.keyId, assertion: toBase64(assertion), challenge: value }),
    );
    expect(replay.status).toBe(401);
  });

  it("returns 404 for an unknown key so the app re-attests", async () => {
    const env = testEnv();
    const device = await createDeviceKey();
    const value = await challenge(env);
    const assertion = await createAssertion({ device, clientDataHash: new Uint8Array(32), counter: 1 });
    const result = await call(
      env,
      post("/v1/assert", { keyId: device.keyId, assertion: toBase64(assertion), challenge: value }),
    );
    expect(result.status).toBe(404);
  });
});

describe("analyze", () => {
  it("requires a valid session", async () => {
    const env = testEnv();
    expect((await call(env, post("/v1/analyze", { text: "x" }))).status).toBe(401);
    expect((await call(env, post("/v1/analyze", { text: "x" }, { Authorization: "Bearer forged.token" }))).status).toBe(
      401,
    );
  });

  it("rate limits per device", async () => {
    const env = testEnv({ DEVICE_LIMITER: new CountingLimiter(1) });
    const { body } = await attestNewDevice(env);
    stubOpenAI({ sounds: [], ambience: null });
    const auth = { Authorization: `Bearer ${body.token}` };
    expect((await call(env, post("/v1/analyze", { text: "one" }, auth))).status).toBe(200);
    expect((await call(env, post("/v1/analyze", { text: "two" }, auth))).status).toBe(429);
  });

  it("rejects an empty or oversized body", async () => {
    const env = testEnv({ ALLOW_DEV_SESSIONS: "true" });
    const { body } = await call(env, post("/v1/dev-session"));
    const auth = { Authorization: `Bearer ${body.token}` };
    expect((await call(env, post("/v1/analyze", {}, auth))).status).toBe(400);
    expect((await call(env, post("/v1/analyze", { text: "x".repeat(40_000) }, auth))).status).toBe(400);
  });
});

describe("dev sessions", () => {
  it("are disabled by default", async () => {
    expect((await call(testEnv(), post("/v1/dev-session"))).status).toBe(404);
  });

  it("work when enabled", async () => {
    const env = testEnv({ ALLOW_DEV_SESSIONS: "true" });
    const { status, body } = await call(env, post("/v1/dev-session"));
    expect(status).toBe(200);
    const payload = JSON.parse(new TextDecoder().decode(fromBase64(body.token.split(".")[0])));
    expect(payload.sub.startsWith("dev:")).toBe(true);
  });
});

describe("auth endpoints", () => {
  it("are rate limited per IP", async () => {
    const env = testEnv({ AUTH_LIMITER: new CountingLimiter(1) });
    expect((await call(env, post("/v1/challenge"))).status).toBe(200);
    expect((await call(env, post("/v1/challenge"))).status).toBe(429);
  });
});
