import { afterEach, describe, expect, it, vi } from "vitest";
import { BUNDLED_CATALOG, UpstreamError } from "../src/analyze";
import { handleRequest } from "../src/index";
import { parsePageRequest, sanitizePage } from "../src/page";
import { testEnv } from "./helpers";

const page = `The wind howled around the little house.
Knock, knock! Somebody was at the
door. "Who is there?" asked the duck.
Outside, the rain kept falling.`;

describe("sanitizePage", () => {
  it("keeps cues whose trigger is on the page, ignoring line breaks and punctuation", () => {
    const result = sanitizePage(
      JSON.stringify({
        cues: [
          { id: "door_knock", trigger: "Knock knock" },
          { id: "door_knock", trigger: "somebody was at the door" },
          { id: "dog_bark", trigger: "the dog barked" }, // not on the page
          { id: "made_up", trigger: "asked the duck" },
          { id: "duck_quack", trigger: "asked the duck" },
          { id: "rain_light", trigger: "the rain kept falling" }, // ambience change mid-page
          { id: "owl_hoot" },
        ],
        ambience: ["wind", "dog_bark"],
        upcoming: ["storm", "duck_quack", "nope"],
      }),
      page,
      BUNDLED_CATALOG,
    );
    expect(result.cues).toEqual([
      { id: "door_knock", trigger: "Knock knock" },
      { id: "door_knock", trigger: "somebody was at the door" },
      { id: "duck_quack", trigger: "asked the duck" },
      { id: "rain_light", trigger: "the rain kept falling" },
    ]);
    expect(result.ambience).toEqual(["wind"]);
    expect(result.upcoming).toEqual(["storm"]);
  });

  it("caps cues and handles empty or invalid answers", () => {
    const many = Array.from({ length: 20 }, () => ({ id: "door_knock", trigger: "knock" }));
    expect(sanitizePage(JSON.stringify({ cues: many }), page, BUNDLED_CATALOG).cues).toHaveLength(16);
    expect(sanitizePage("{}", page, BUNDLED_CATALOG)).toEqual({ cues: [], ambience: null, upcoming: [], missing: [] });
    expect(() => sanitizePage("nope", page, BUNDLED_CATALOG)).toThrow(UpstreamError);
  });

  it("matches Chinese triggers", () => {
    const result = sanitizePage(
      JSON.stringify({ cues: [{ id: "dog_bark", trigger: "小狗汪汪叫" }] }),
      "早上，\n小狗汪汪叫。",
      BUNDLED_CATALOG,
    );
    expect(result.cues.map((c) => c.id)).toEqual(["dog_bark"]);
  });
});

describe("parsePageRequest", () => {
  it("requires text and trims long pages", () => {
    expect(parsePageRequest({ text: " " })).toBeNull();
    expect(parsePageRequest({ text: "x", context: 5 })).toBeNull();
    expect(parsePageRequest({ text: "x".repeat(5000) })?.text).toHaveLength(4000);
  });
});

describe("POST /v1/analyze-page", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("returns cues for a page", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            choices: [{ message: { content: JSON.stringify({ cues: [{ id: "door_knock", trigger: "knock knock" }], ambience: ["wind"] }) } }],
          }),
        ),
    );
    vi.stubGlobal("fetch", fetchMock);
    const env = testEnv({ ALLOW_DEV_SESSIONS: "true" });
    const { token } = (await (
      await handleRequest(new Request("https://api.test/v1/dev-session", { method: "POST" }), env)
    ).json()) as { token: string };
    const post = (body: unknown) =>
      handleRequest(
        new Request("https://api.test/v1/analyze-page", {
          method: "POST",
          headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
          body: JSON.stringify(body),
        }),
        env,
      );

    const response = await post({ text: page });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ cues: [{ id: "door_knock", trigger: "knock knock" }], ambience: ["wind"], upcoming: [] });
    const sent = JSON.parse((fetchMock.mock.calls[0] as unknown as [string, RequestInit])[1].body as string);
    expect(sent.messages[1].content).toBe(`Page: ${page}`);

    expect((await post({ text: "" })).status).toBe(400);
  });
});
