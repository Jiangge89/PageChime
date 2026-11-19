/**
 * Stateless, HMAC-signed challenges and session tokens.
 *
 * A device proves itself with App Attest once, then uses a short-lived
 * session token for analysis requests, so the per-request path needs no
 * signature checks or storage writes.
 */
import { equalBytes, fromBase64, textEncoder, toBase64Url } from "./encoding";

export const CHALLENGE_TTL_MS = 5 * 60 * 1000;
export const SESSION_TTL_SECONDS = 60 * 60;

export interface Session {
  /** Device identity: the App Attest key ID, or "dev:<id>" for local development. */
  sub: string;
  /** Expiry, seconds since epoch. */
  exp: number;
}

async function hmac(secret: string, message: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    textEncoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, textEncoder.encode(message)));
}

export async function createChallenge(secret: string, now = Date.now()): Promise<string> {
  const payload = `${now}.${toBase64Url(crypto.getRandomValues(new Uint8Array(16)))}`;
  return `${payload}.${toBase64Url(await hmac(secret, `challenge:${payload}`))}`;
}

export async function verifyChallenge(secret: string, challenge: string, now = Date.now()): Promise<boolean> {
  const parts = challenge.split(".");
  if (parts.length !== 3) return false;
  const payload = `${parts[0]}.${parts[1]}`;
  const expected = await hmac(secret, `challenge:${payload}`);
  let signature: Uint8Array;
  try {
    signature = fromBase64(parts[2]);
  } catch {
    return false;
  }
  if (!equalBytes(expected, signature)) return false;
  const issuedAt = Number(parts[0]);
  return Number.isFinite(issuedAt) && issuedAt <= now && now - issuedAt <= CHALLENGE_TTL_MS;
}

export async function createSessionToken(
  secret: string,
  sub: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<{ token: string; expiresIn: number }> {
  const session: Session = { sub, exp: nowSeconds + SESSION_TTL_SECONDS };
  const payload = toBase64Url(textEncoder.encode(JSON.stringify(session)));
  const signature = toBase64Url(await hmac(secret, `session:${payload}`));
  return { token: `${payload}.${signature}`, expiresIn: SESSION_TTL_SECONDS };
}

export async function verifySessionToken(
  secret: string,
  token: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<Session | null> {
  const parts = token.split(".");
  if (parts.length !== 2) return null;
  try {
    const expected = await hmac(secret, `session:${parts[0]}`);
    if (!equalBytes(expected, fromBase64(parts[1]))) return null;
    const session = JSON.parse(new TextDecoder().decode(fromBase64(parts[0]))) as Session;
    if (typeof session.sub !== "string" || typeof session.exp !== "number") return null;
    return session.exp > nowSeconds ? session : null;
  } catch {
    return null;
  }
}
