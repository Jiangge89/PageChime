import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { handleRequest, type Env } from "../src/index";
import { mergedCatalog, resetManifestCache, validateManifest } from "../src/library";
import { MemoryObjectStore, testEnv } from "./helpers";

const wolf = {
  id: "wolf_howl",
  kind: "oneShot",
  name: "wolf",
  description: "a lone wolf howling at night",
  category: "animal",
  variants: [
    { file: "wolf_howl.1a2b3c4d.m4a", duration: 4.2, bytes: 67_000 },
    { file: "wolf_howl.5e6f7a8b.m4a", duration: 3.8, bytes: 61_000 },
  ],
};
const cave = {
  id: "cave_drips",
  kind: "ambience",
  name: "cave",
  description: "dripping water echoing in a cave",
  category: "environment",
  variants: [{ file: "cave_drips.0badf00d.m4a", duration: 75, bytes: 1_200_000 }],
};

beforeEach(() => resetManifestCache());
afterEach(() => vi.unstubAllGlobals());

describe("validateManifest", () => {
  it("keeps valid sounds", () => {
    const manifest = validateManifest({ version: 3, sounds: [wolf, cave] });
    expect(manifest.version).toBe(3);
    expect(manifest.sounds.map((s) => s.id)).toEqual(["wolf_howl", "cave_drips"]);
  });

  it("drops malformed sounds and variants instead of failing", () => {
    const manifest = validateManifest({
      version: 1,
      sounds: [
        { ...wolf, id: "Bad ID" },
        { ...wolf, kind: "loop" },
        { ...wolf, id: "no_variants", variants: [] },
        { ...wolf, id: "bad_file", variants: [{ file: "../../etc/passwd", duration: 1, bytes: 1 }] },
        { ...cave, category: "spaceship", name: undefined },
        { ...cave },
      ],
    });
    expect(manifest.sounds).toHaveLength(1);
    expect(manifest.sounds[0].category).toBe("environment");
    expect(manifest.sounds[0].name).toBe("cave drips");
  });

  it("treats garbage as an empty library", () => {
    expect(validateManifest("nope")).toEqual({ version: 0, sounds: [] });
  });
});

describe("mergedCatalog", () => {
  it("adds library sounds without duplicating bundled ones", () => {
    const manifest = validateManifest({ version: 1, sounds: [wolf, cave, { ...wolf, id: "thunder" }] });
    const catalog = mergedCatalog(manifest);
    expect(catalog.filter((s) => s.id === "thunder")).toHaveLength(1);
    expect(catalog.find((s) => s.id === "wolf_howl")?.ambience).toBe(false);
    expect(catalog.find((s) => s.id === "cave_drips")?.ambience).toBe(true);
  });
});

describe("library routes", () => {
  async function sessionEnv(): Promise<{ env: Env; store: MemoryObjectStore; auth: Record<string, string> }> {
    const store = new MemoryObjectStore();
    store.put("library.json", JSON.stringify({ version: 2, sounds: [wolf, cave] }));
    store.put("sounds/wolf_howl.1a2b3c4d.m4a", new Uint8Array([1, 2, 3, 4]));
    const env = testEnv({ ALLOW_DEV_SESSIONS: "true", SOUNDS: store });
    const session = await handleRequest(new Request("https://api.test/v1/dev-session", { method: "POST" }), env);
    const { token } = (await session.json()) as { token: string };
    return { env, store, auth: { Authorization: `Bearer ${token}` } };
  }

  const get = (env: Env, path: string, headers: Record<string, string> = {}) =>
    handleRequest(new Request(`https://api.test${path}`, { headers }), env);

  it("require a session", async () => {
    const { env } = await sessionEnv();
    expect((await get(env, "/v1/library")).status).toBe(401);
    expect((await get(env, "/v1/sounds/wolf_howl.1a2b3c4d.m4a")).status).toBe(401);
  });

  it("serve the manifest with an ETag and answer 304 when unchanged", async () => {
    const { env, auth } = await sessionEnv();
    const response = await get(env, "/v1/library", auth);
    expect(response.status).toBe(200);
    const body = (await response.json()) as { version: number; sounds: unknown[] };
    expect(body.version).toBe(2);
    expect(body.sounds).toHaveLength(2);

    const etag = response.headers.get("ETag")!;
    expect(etag).toBeTruthy();
    expect((await get(env, "/v1/library", { ...auth, "If-None-Match": etag })).status).toBe(304);
  });

  it("serve an empty library when there is no bucket", async () => {
    const { auth } = await sessionEnv();
    const env = testEnv({ ALLOW_DEV_SESSIONS: "true" });
    const tokenEnv = { ...env, TOKEN_SECRET: "test-token-secret" };
    const response = await get(tokenEnv, "/v1/library", auth);
    expect(await response.json()).toEqual({ version: 0, sounds: [] });
  });

  it("serve sound files with immutable caching", async () => {
    const { env, auth } = await sessionEnv();
    const response = await get(env, "/v1/sounds/wolf_howl.1a2b3c4d.m4a", auth);
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("audio/mp4");
    expect(response.headers.get("Cache-Control")).toContain("immutable");
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3, 4]));
  });

  it("reject unknown or unsafe file names", async () => {
    const { env, auth } = await sessionEnv();
    expect((await get(env, "/v1/sounds/wolf_howl.5e6f7a8b.m4a", auth)).status).toBe(404);
    expect((await get(env, "/v1/sounds/..%2Flibrary.json", auth)).status).toBe(404);
    expect((await get(env, "/v1/sounds/library.json", auth)).status).toBe(404);
  });

  it("let the LLM choose library sounds", async () => {
    const { env, auth } = await sessionEnv();
    const fetchMock = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            choices: [
              {
                message: {
                  content: JSON.stringify({
                    sounds: [{ id: "wolf_howl", trigger: "a wolf howled" }],
                    ambience: ["cave_drips"],
                    upcoming: ["owl_hoot", "cave_drips"],
                  }),
                },
              },
            ],
          }),
        ),
    );
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleRequest(
      new Request("https://api.test/v1/analyze", {
        method: "POST",
        headers: { ...auth, "Content-Type": "application/json" },
        body: JSON.stringify({ text: "a wolf howled in the cave", context: "" }),
      }),
      env,
    );
    expect(await response.json()).toEqual({
      sounds: [{ id: "wolf_howl", trigger: "a wolf howled" }],
      ambience: ["cave_drips"],
      upcoming: ["owl_hoot"],
    });
    const body = JSON.parse((fetchMock.mock.calls[0] as unknown as [string, RequestInit])[1].body as string);
    expect(body.messages[0].content).toContain("- wolf_howl: a lone wolf howling at night");
    expect(body.messages[0].content).toContain("- cave_drips: dripping water echoing in a cave");
  });
});
