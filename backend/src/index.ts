/**
 * PageChime API — keeps the OpenAI key off the device.
 *
 * Flow:
 *   1. POST /v1/challenge            → one-time challenge
 *   2. POST /v1/attest  (new key)    → App Attest attestation  → session token
 *      POST /v1/assert  (known key)  → App Attest assertion    → session token
 *   3. POST /v1/analyze (Bearer)     → sound analysis for new story text
 *      GET  /v1/library (Bearer)     → cloud sound library manifest
 *      GET  /v1/sounds/<file> (Bearer) → audio file from the library
 *
 * In local development (ALLOW_DEV_SESSIONS=true), POST /v1/dev-session
 * returns a token without App Attest, since the simulator can't attest.
 */
import { AttestationError, verifyAssertion, verifyAttestation, type AttestedKey } from "./appAttest";
import { analyzeWithOpenAI, parseAnalyzeRequest, SoundCatalog, UpstreamError } from "./analyze";
import { APPLE_APP_ATTEST_ROOT_PEM } from "./appleRoot";
import { fromBase64, pemToDer, sha256, textEncoder, toBase64Url } from "./encoding";
import { recordGaps, type GapDatabase } from "./gaps";
import { FILE_PATTERN, loadManifest, mergedCatalog, SOUND_PREFIX, type ObjectStore } from "./library";
import { createChallenge, createSessionToken, verifyChallenge, verifySessionToken, type Session } from "./tokens";

/** Subset of the Workers rate limiting binding we use. */
export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

/** Subset of a KV namespace we use. */
export interface KeyStore {
  get(key: string): Promise<string | null>;
  put(key: string, value: string): Promise<void>;
}

export interface Env {
  OPENAI_API_KEY: string;
  TOKEN_SECRET: string;
  /** "<Team ID>.<bundle ID>" — App Attest keys are bound to it. */
  APP_ID: string;
  OPENAI_MODEL?: string;
  ALLOW_DEV_SESSIONS?: string;
  DEVICE_KEYS: KeyStore;
  /** Per-device limit on analysis requests. */
  DEVICE_LIMITER: RateLimiter;
  /** Per-IP limit on challenge, attest, assert and dev-session requests. */
  AUTH_LIMITER: RateLimiter;
  /** Per-device limit on library and sound file requests. */
  SOUNDS_LIMITER: RateLimiter;
  /** R2 bucket with library.json and sounds/. Optional: without it the library is empty. */
  SOUNDS?: ObjectStore;
  /** D1 database counting sounds stories asked for that the library lacks. Optional. */
  GAPS?: GapDatabase;
}

export interface RequestOptions {
  /** Test-only: the App Attest root to trust instead of Apple's. */
  rootCertificate?: Uint8Array;
  /** Keeps background work (gap logging) alive after the response is sent. */
  waitUntil?: (promise: Promise<unknown>) => void;
}

let catalogCache: { json: string; catalog: SoundCatalog } | null = null;

/** The analysis catalog for the current library, rebuilt only when it changes. */
async function currentCatalog(env: Env): Promise<SoundCatalog> {
  const { manifest, json } = await loadManifest(env.SOUNDS);
  if (catalogCache?.json !== json) {
    catalogCache = { json, catalog: new SoundCatalog(mergedCatalog(manifest)) };
  }
  return catalogCache.catalog;
}

async function sessionFrom(request: Request, env: Env): Promise<Session | null> {
  const auth = request.headers.get("Authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  return token ? verifySessionToken(env.TOKEN_SECRET, token) : null;
}

async function serveSound(file: string, env: Env): Promise<Response> {
  // Files are content-hashed, so the edge cache can keep them forever.
  // (The Cache API is a no-op on workers.dev; it works on a custom domain.)
  const edgeCache = typeof caches !== "undefined" ? (caches as unknown as { default: Cache }).default : null;
  const cacheKey = new Request(`https://sound-cache.internal/${file}`);
  const hit = await edgeCache?.match(cacheKey);
  if (hit) return hit;

  const object = await env.SOUNDS?.get(SOUND_PREFIX + file);
  if (!object?.body) return error(404, "not found");
  const response = new Response(object.body, {
    headers: {
      "Content-Type": "audio/mp4",
      "Content-Length": String(object.size),
      "Cache-Control": "public, max-age=31536000, immutable",
      ETag: object.httpEtag,
    },
  });
  if (edgeCache) await edgeCache.put(cacheKey, response.clone());
  return response;
}

const MAX_BODY_BYTES = 32 * 1024;
const APPLE_ROOT_DER = pemToDer(APPLE_APP_ATTEST_ROOT_PEM);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function error(status: number, message: string): Response {
  return json({ error: message }, status);
}

async function readJson(request: Request): Promise<Record<string, unknown> | null> {
  const text = await request.text();
  if (textEncoder.encode(text).length > MAX_BODY_BYTES) return null;
  try {
    const parsed = JSON.parse(text);
    return typeof parsed === "object" && parsed !== null ? parsed : null;
  } catch {
    return null;
  }
}

function clientIp(request: Request): string {
  return request.headers.get("CF-Connecting-IP") ?? "local";
}

function keyStoreKey(keyId: string): string {
  return `key:${keyId}`;
}

export async function handleRequest(request: Request, env: Env, options: RequestOptions = {}) {
  const { pathname } = new URL(request.url);

  if (request.method === "GET" && pathname === "/v1/health") {
    return json({ ok: true });
  }

  if (request.method === "GET" && (pathname === "/v1/library" || pathname.startsWith("/v1/sounds/"))) {
    const session = await sessionFrom(request, env);
    if (!session) return error(401, "session invalid or expired");
    if (!(await env.SOUNDS_LIMITER.limit({ key: session.sub })).success) return error(429, "rate limited");

    if (pathname === "/v1/library") {
      const { json: body, etag } = await loadManifest(env.SOUNDS);
      const headers: Record<string, string> = { "Content-Type": "application/json", "Cache-Control": "no-cache" };
      if (etag) {
        headers.ETag = etag;
        if (request.headers.get("If-None-Match") === etag) return new Response(null, { status: 304, headers });
      }
      return new Response(body, { headers });
    }

    const file = decodeURIComponent(pathname.slice("/v1/sounds/".length));
    if (!FILE_PATTERN.test(file)) return error(404, "not found");
    return serveSound(file, env);
  }
  if (request.method !== "POST") return error(404, "not found");

  switch (pathname) {
    case "/v1/challenge": {
      if (!(await env.AUTH_LIMITER.limit({ key: clientIp(request) })).success) return error(429, "rate limited");
      return json({ challenge: await createChallenge(env.TOKEN_SECRET) });
    }

    case "/v1/attest": {
      if (!(await env.AUTH_LIMITER.limit({ key: clientIp(request) })).success) return error(429, "rate limited");
      const body = await readJson(request);
      const { keyId, attestation, challenge } = body ?? {};
      if (typeof keyId !== "string" || typeof attestation !== "string" || typeof challenge !== "string") {
        return error(400, "keyId, attestation and challenge are required");
      }
      if (!(await verifyChallenge(env.TOKEN_SECRET, challenge))) return error(401, "challenge invalid or expired");
      if (await env.DEVICE_KEYS.get(keyStoreKey(keyId))) return error(409, "key already attested");

      let attested: AttestedKey;
      try {
        attested = await verifyAttestation({
          keyId,
          attestation: fromBase64(attestation),
          clientDataHash: await sha256(textEncoder.encode(challenge)),
          appId: env.APP_ID,
          rootCertificate: options.rootCertificate ?? APPLE_ROOT_DER,
        });
      } catch (e) {
        if (e instanceof AttestationError) return error(401, `attestation rejected: ${e.message}`);
        throw e;
      }
      await env.DEVICE_KEYS.put(keyStoreKey(keyId), JSON.stringify(attested));
      return json(await createSessionToken(env.TOKEN_SECRET, keyId));
    }

    case "/v1/assert": {
      if (!(await env.AUTH_LIMITER.limit({ key: clientIp(request) })).success) return error(429, "rate limited");
      const body = await readJson(request);
      const { keyId, assertion, challenge } = body ?? {};
      if (typeof keyId !== "string" || typeof assertion !== "string" || typeof challenge !== "string") {
        return error(400, "keyId, assertion and challenge are required");
      }
      if (!(await verifyChallenge(env.TOKEN_SECRET, challenge))) return error(401, "challenge invalid or expired");

      const stored = await env.DEVICE_KEYS.get(keyStoreKey(keyId));
      // 404 tells the app to generate and attest a new key.
      if (!stored) return error(404, "unknown key");
      const key = JSON.parse(stored) as AttestedKey;

      let counter: number;
      try {
        counter = await verifyAssertion({
          assertion: fromBase64(assertion),
          clientDataHash: await sha256(textEncoder.encode(challenge)),
          key,
          appId: env.APP_ID,
        });
      } catch (e) {
        if (e instanceof AttestationError) return error(401, `assertion rejected: ${e.message}`);
        throw e;
      }
      await env.DEVICE_KEYS.put(keyStoreKey(keyId), JSON.stringify({ ...key, counter }));
      return json(await createSessionToken(env.TOKEN_SECRET, keyId));
    }

    case "/v1/dev-session": {
      if (env.ALLOW_DEV_SESSIONS !== "true") return error(404, "not found");
      if (!(await env.AUTH_LIMITER.limit({ key: clientIp(request) })).success) return error(429, "rate limited");
      const id = toBase64Url(crypto.getRandomValues(new Uint8Array(9)));
      return json(await createSessionToken(env.TOKEN_SECRET, `dev:${id}`));
    }

    case "/v1/analyze": {
      const session = await sessionFrom(request, env);
      if (!session) return error(401, "session invalid or expired");
      if (!(await env.DEVICE_LIMITER.limit({ key: session.sub })).success) return error(429, "rate limited");

      const analyzeRequest = parseAnalyzeRequest(await readJson(request));
      if (!analyzeRequest) return error(400, "text is required");

      try {
        const { missing, ...result } = await analyzeWithOpenAI(analyzeRequest, {
          apiKey: env.OPENAI_API_KEY,
          model: env.OPENAI_MODEL || "gpt-4o-mini",
          catalog: await currentCatalog(env),
        });
        if (env.GAPS && missing.length > 0) {
          const logging = recordGaps(env.GAPS, missing, session.sub).catch((e) =>
            console.warn("gap logging failed", e instanceof Error ? e.message : e),
          );
          if (options.waitUntil) options.waitUntil(logging);
          else await logging;
        }
        return json(result);
      } catch (e) {
        if (e instanceof UpstreamError) {
          console.warn(`analyze failed: ${e.message}`);
          return error(e.status, e.message);
        }
        throw e;
      }
    }

    default:
      return error(404, "not found");
  }
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      return await handleRequest(request, env, { waitUntil: (promise) => ctx.waitUntil(promise) });
    } catch (e) {
      console.error("unhandled error", e instanceof Error ? e.message : e);
      return error(500, "internal error");
    }
  },
};
