import { describe, expect, it, vi } from "vitest";
import {
  analyzeWithOpenAI,
  buildUserMessage,
  MAX_CONTEXT_LENGTH,
  parseAnalyzeRequest,
  sanitizeResult,
  BUNDLED_CATALOG,
  UpstreamError,
} from "../src/analyze";

function openAIResponse(content: unknown, status = 200): Response {
  return new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(content) } }] }), { status });
}

describe("parseAnalyzeRequest", () => {
  it("requires non-empty text", () => {
    expect(parseAnalyzeRequest({ text: "  " })).toBeNull();
    expect(parseAnalyzeRequest({ context: "x" })).toBeNull();
    expect(parseAnalyzeRequest(null)).toBeNull();
  });

  it("keeps the end of a long context", () => {
    const context = "a".repeat(MAX_CONTEXT_LENGTH) + "END";
    const parsed = parseAnalyzeRequest({ text: "hi", context });
    expect(parsed?.context.length).toBe(MAX_CONTEXT_LENGTH);
    expect(parsed?.context.endsWith("END")).toBe(true);
  });
});

describe("buildUserMessage", () => {
  it("matches the format the app used", () => {
    expect(buildUserMessage({ text: "new", context: "" })).toBe("New text: new");
    expect(buildUserMessage({ text: "new", context: "old" })).toBe("Story so far: old\n\nNew text: new");
  });
});

describe("sanitizeResult", () => {
  it("drops unknown ids and malformed items", () => {
    const result = sanitizeResult(
      JSON.stringify({
        sounds: [
          { id: "dog_bark", trigger: "the dog" },
          { id: "made_up", trigger: "x" },
          { id: "cat_meow" },
          "nonsense",
          { id: "dog_bark", trigger: "again" },
        ],
        ambience: ["forest_ambience", "dog_bark", "not_real"],
      }),
    );
    expect(result.sounds).toEqual([{ id: "dog_bark", trigger: "the dog" }]);
    expect(result.ambience).toEqual(["forest_ambience"]);
  });

  it("distinguishes null (keep scene) from [] (quiet scene)", () => {
    expect(sanitizeResult(JSON.stringify({ sounds: [], ambience: null })).ambience).toBeNull();
    expect(sanitizeResult(JSON.stringify({ sounds: [] })).ambience).toBeNull();
    expect(sanitizeResult(JSON.stringify({ sounds: [], ambience: [] })).ambience).toEqual([]);
  });

  it("caps one-shots at four and passes inline ambience through", () => {
    const ids = ["dog_bark", "cat_meow", "frog_croak", "cow_moo", "owl_hoot"];
    const result = sanitizeResult(
      JSON.stringify({ sounds: [...ids, "storm"].map((id) => ({ id, trigger: id })) }),
    );
    expect(result.sounds.map((s) => s.id)).toEqual(["dog_bark", "cat_meow", "frog_croak", "cow_moo", "storm"]);
  });

  it("keeps known upcoming ids that aren't already chosen", () => {
    const result = sanitizeResult(
      JSON.stringify({
        sounds: [{ id: "door_knock", trigger: "knock" }],
        ambience: ["forest_ambience"],
        upcoming: ["owl_hoot", "door_knock", "forest_ambience", "made_up", 7, "owl_hoot", "storm"],
      }),
    );
    expect(result.upcoming).toEqual(["owl_hoot", "storm"]);
    expect(sanitizeResult(JSON.stringify({ sounds: [] })).upcoming).toEqual([]);
    const many = ["dog_bark", "cat_meow", "frog_croak", "cow_moo", "owl_hoot", "storm", "wind", "rain_light"];
    expect(sanitizeResult(JSON.stringify({ sounds: [], upcoming: many })).upcoming).toHaveLength(6);
  });

  it("throws on invalid JSON", () => {
    expect(() => sanitizeResult("not json")).toThrow(UpstreamError);
  });
});

describe("analyzeWithOpenAI", () => {
  it("sends the prompt and returns the sanitized result", async () => {
    const fetcher = vi.fn(async () => openAIResponse({ sounds: [{ id: "owl_hoot", trigger: "owl" }], ambience: null }));
    const result = await analyzeWithOpenAI(
      { text: "an owl", context: "night" },
      { apiKey: "key", model: "gpt-4o-mini", fetcher },
    );
    expect(result).toEqual({ sounds: [{ id: "owl_hoot", trigger: "owl" }], ambience: null, upcoming: [] });

    const [url, init] = fetcher.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://api.openai.com/v1/chat/completions");
    expect((init.headers as Record<string, string>).Authorization).toBe("Bearer key");
    const body = JSON.parse(init.body as string);
    expect(body.model).toBe("gpt-4o-mini");
    expect(body.messages[0].content).toBe(BUNDLED_CATALOG.systemPrompt);
    expect(body.messages[1].content).toBe("Story so far: night\n\nNew text: an owl");
  });

  it("maps a timeout to 504", async () => {
    const fetcher = vi.fn(async (_url: RequestInfo | URL, init?: RequestInit) => {
      await new Promise((_, reject) => init?.signal?.addEventListener("abort", () => reject(init.signal!.reason)));
      return openAIResponse({});
    });
    await expect(
      analyzeWithOpenAI({ text: "x", context: "" }, { apiKey: "k", model: "m", fetcher, timeoutMs: 10 }),
    ).rejects.toMatchObject({ status: 504 });
  });

  it("passes upstream rate limits through as 429", async () => {
    const fetcher = vi.fn(async () => new Response("{}", { status: 429 }));
    await expect(
      analyzeWithOpenAI({ text: "x", context: "" }, { apiKey: "k", model: "m", fetcher }),
    ).rejects.toMatchObject({ status: 429 });
  });

  it("maps other upstream errors to 502", async () => {
    const fetcher = vi.fn(async () => new Response("{}", { status: 500 }));
    await expect(
      analyzeWithOpenAI({ text: "x", context: "" }, { apiKey: "k", model: "m", fetcher }),
    ).rejects.toMatchObject({ status: 502 });
  });
});
