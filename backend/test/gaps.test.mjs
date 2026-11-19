// Plain JS so it can use node:sqlite (the worker's tsconfig has no Node types).
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it, vi } from "vitest";
import { recordGaps } from "../src/gaps";
import { handleRequest } from "../src/index";
import { testEnv } from "./helpers";

/** D1's prepare/bind/run on an in-memory SQLite, so the real SQL runs. */
export class SqliteGapDatabase {
  db = new DatabaseSync(":memory:");
  prepare(query) {
    const db = this.db;
    let values = [];
    const statement = {
      bind: (...v) => {
        values = v;
        return statement;
      },
      run: async () => ({ meta: { changes: Number(db.prepare(query).run(...values).changes) } }),
    };
    return statement;
  }
  rows() {
    return this.db.prepare("SELECT id, kind, description, requests, devices FROM gaps ORDER BY id").all().map((r) => ({ ...r }));
  }
}

const seal = { id: "seal_bark", kind: "oneShot", description: "a seal barking" };
const jungle = { id: "jungle_ambience", kind: "ambience", description: "a humid jungle with birds" };

describe("recordGaps", () => {
  it("counts requests and distinct devices", async () => {
    const db = new SqliteGapDatabase();
    await recordGaps(db, [seal, jungle], "device-a");
    await recordGaps(db, [seal], "device-a");
    await recordGaps(db, [{ ...seal, description: "a seal, barking loudly" }], "device-b");

    expect(db.rows()).toEqual([
      { id: "jungle_ambience", kind: "ambience", description: "a humid jungle with birds", requests: 1, devices: 1 },
      { id: "seal_bark", kind: "oneShot", description: "a seal barking", requests: 3, devices: 2 },
    ]);
  });

  it("does nothing without gaps", async () => {
    const db = new SqliteGapDatabase();
    await recordGaps(db, [], "device-a");
    expect(() => db.rows()).toThrow(/no such table/);
  });
});

describe("analyze route", () => {
  afterEach(() => vi.unstubAllGlobals());

  async function analyze(env, modelOutput) {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(modelOutput) } }] }))),
    );
    const { token } = await (
      await handleRequest(new Request("https://api.test/v1/dev-session", { method: "POST" }), env)
    ).json();
    const pending = [];
    const response = await handleRequest(
      new Request("https://api.test/v1/analyze", {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ text: "The seal barked and the dog barked", context: "" }),
      }),
      env,
      { waitUntil: (p) => pending.push(p) },
    );
    await Promise.all(pending);
    return response.json();
  }

  it("logs missing sounds in the background and doesn't send them to the app", async () => {
    const gaps = new SqliteGapDatabase();
    const env = testEnv({ ALLOW_DEV_SESSIONS: "true", GAPS: gaps });
    const body = await analyze(env, {
      sounds: [{ id: "dog_bark", trigger: "the dog barked" }],
      ambience: null,
      upcoming: [],
      missing: [seal, { id: "dog_bark", kind: "oneShot", description: "already in the catalog" }],
    });

    expect(body).toEqual({ sounds: [{ id: "dog_bark", trigger: "the dog barked" }], ambience: null, upcoming: [] });
    expect(gaps.rows().map((r) => r.id)).toEqual(["seal_bark"]);
  });

  it("still answers when there is no gap database or logging fails", async () => {
    const missing = [seal];
    expect((await analyze(testEnv({ ALLOW_DEV_SESSIONS: "true" }), { sounds: [], missing })).sounds).toEqual([]);

    const broken = { prepare: () => ({ bind() { return this; }, run: async () => { throw new Error("D1 down"); } }) };
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const body = await analyze(testEnv({ ALLOW_DEV_SESSIONS: "true", GAPS: broken }), { sounds: [], missing });
    expect(body.sounds).toEqual([]);
    expect(warn).toHaveBeenCalled();
    warn.mockRestore();
  });
});
