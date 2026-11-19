import { describe, expect, it } from "vitest";
import {
  CHALLENGE_TTL_MS,
  createChallenge,
  createSessionToken,
  SESSION_TTL_SECONDS,
  verifyChallenge,
  verifySessionToken,
} from "../src/tokens";

const SECRET = "secret";

describe("challenges", () => {
  it("verifies a fresh challenge", async () => {
    expect(await verifyChallenge(SECRET, await createChallenge(SECRET))).toBe(true);
  });

  it("rejects an expired challenge", async () => {
    const now = Date.now();
    const challenge = await createChallenge(SECRET, now - CHALLENGE_TTL_MS - 1);
    expect(await verifyChallenge(SECRET, challenge, now)).toBe(false);
  });

  it("rejects a challenge signed with another secret", async () => {
    expect(await verifyChallenge(SECRET, await createChallenge("other"))).toBe(false);
  });

  it("rejects a tampered challenge", async () => {
    const [time, random, signature] = (await createChallenge(SECRET)).split(".");
    expect(await verifyChallenge(SECRET, `${Number(time) + 1}.${random}.${signature}`)).toBe(false);
    expect(await verifyChallenge(SECRET, "not-a-challenge")).toBe(false);
  });
});

describe("session tokens", () => {
  it("round-trips the subject", async () => {
    const { token, expiresIn } = await createSessionToken(SECRET, "device-1");
    expect(expiresIn).toBe(SESSION_TTL_SECONDS);
    expect((await verifySessionToken(SECRET, token))?.sub).toBe("device-1");
  });

  it("rejects an expired token", async () => {
    const now = Math.floor(Date.now() / 1000);
    const { token } = await createSessionToken(SECRET, "device-1", now - SESSION_TTL_SECONDS - 1);
    expect(await verifySessionToken(SECRET, token, now)).toBeNull();
  });

  it("rejects a token with a modified subject", async () => {
    const { token } = await createSessionToken(SECRET, "device-1");
    const [, signature] = token.split(".");
    const forged = btoa(JSON.stringify({ sub: "device-2", exp: 9_999_999_999 })).replace(/=+$/, "");
    expect(await verifySessionToken(SECRET, `${forged}.${signature}`)).toBeNull();
    expect(await verifySessionToken(SECRET, "garbage")).toBeNull();
  });
});
