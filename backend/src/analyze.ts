import { CATALOG, type CatalogSound } from "./catalog";

export const MAX_TEXT_LENGTH = 1000;
export const MAX_CONTEXT_LENGTH = 1000;
const MAX_SOUNDS = 4;
const MAX_AMBIENCE = 3;

export interface AnalyzeRequest {
  text: string;
  context: string;
}

export interface SoundMatch {
  id: string;
  trigger: string;
}

export interface AnalyzeResult {
  sounds: SoundMatch[];
  /** Ambience for the current scene, or null to keep the current scene. */
  ambience: string[] | null;
}

export class UpstreamError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

/** A set of sounds the LLM may choose from, with the prompt built for it. */
export class SoundCatalog {
  readonly oneShotIds: Set<string>;
  readonly ambienceIds: Set<string>;
  readonly systemPrompt: string;

  constructor(readonly sounds: CatalogSound[]) {
    this.oneShotIds = new Set(sounds.filter((s) => !s.ambience).map((s) => s.id));
    this.ambienceIds = new Set(sounds.filter((s) => s.ambience).map((s) => s.id));
    this.systemPrompt = buildSystemPrompt(sounds);
  }
}

function catalogSection(sounds: CatalogSound[], ambience: boolean): string {
  return sounds
    .filter((s) => Boolean(s.ambience) === ambience)
    .map((s) => `- ${s.id}: ${s.description}`)
    .join("\n");
}

function buildSystemPrompt(sounds: CatalogSound[]): string {
  return `You add sound effects, in real time, to a children's story that a parent is reading aloud. You receive the story read so far (context) and the newly read text.

One-shot sounds (play once when the new text describes them happening):
${catalogSection(sounds, false)}

Ambience beds (looping background for the current setting):
${catalogSection(sounds, true)}

Return JSON: {"sounds": [{"id": "sound_id", "trigger": "phrase"}], "ambience": ["sound_id"] or null}

Rules:
- "sounds": one-shots for things happening in the NEW text only, never for things only in the context. Skip negated events (e.g. "not a dog", "没有狗"). At most ${MAX_SOUNDS}.
- "trigger": the shortest phrase copied verbatim from the new text that identifies the sound.
- "ambience": 0-${MAX_AMBIENCE} ambience ids for where the story is at the end of the new text. Use the context to understand the setting, and keep the same set while the setting doesn't change. Return null if the new text says nothing about the setting. Return [] only if the story clearly moves somewhere quiet.
- Only use ids from the lists above.`;
}

/** The sounds bundled in the app. */
export const BUNDLED_CATALOG = new SoundCatalog(CATALOG);

/** Validates and trims the request body; returns null if it's unusable. */
export function parseAnalyzeRequest(body: unknown): AnalyzeRequest | null {
  if (typeof body !== "object" || body === null) return null;
  const { text, context } = body as Record<string, unknown>;
  if (typeof text !== "string" || text.trim().length === 0) return null;
  if (context !== undefined && typeof context !== "string") return null;
  return {
    text: text.slice(0, MAX_TEXT_LENGTH),
    // Keep the end of the context: it's the part closest to the new text.
    context: (context ?? "").slice(-MAX_CONTEXT_LENGTH),
  };
}

export function buildUserMessage({ text, context }: AnalyzeRequest): string {
  return context ? `Story so far: ${context}\n\nNew text: ${text}` : `New text: ${text}`;
}

/** Keeps only well-formed, known sounds from the model's JSON output. */
export function sanitizeResult(content: string, catalog: SoundCatalog = BUNDLED_CATALOG): AnalyzeResult {
  let parsed: unknown;
  try {
    parsed = JSON.parse(content);
  } catch {
    throw new UpstreamError("model returned invalid JSON", 502);
  }
  const object = (typeof parsed === "object" && parsed !== null ? parsed : {}) as Record<string, unknown>;

  // One-shots are capped at MAX_SOUNDS. Ambience ids returned as sounds are
  // passed through too (the app adds them as beds), capped at MAX_AMBIENCE.
  const oneShots: SoundMatch[] = [];
  const inlineAmbience: SoundMatch[] = [];
  const seen = new Set<string>();
  for (const item of Array.isArray(object.sounds) ? object.sounds : []) {
    if (typeof item !== "object" || item === null) continue;
    const { id, trigger } = item as Record<string, unknown>;
    if (typeof id !== "string" || typeof trigger !== "string" || seen.has(id)) continue;
    const match = { id, trigger: trigger.slice(0, 200) };
    if (catalog.oneShotIds.has(id) && oneShots.length < MAX_SOUNDS) {
      seen.add(id);
      oneShots.push(match);
    } else if (catalog.ambienceIds.has(id) && inlineAmbience.length < MAX_AMBIENCE) {
      seen.add(id);
      inlineAmbience.push(match);
    }
  }

  let ambience: string[] | null = null;
  if (Array.isArray(object.ambience)) {
    ambience = [
      ...new Set(object.ambience.filter((id): id is string => typeof id === "string" && catalog.ambienceIds.has(id))),
    ];
    ambience = ambience.slice(0, MAX_AMBIENCE);
  }

  return { sounds: [...oneShots, ...inlineAmbience], ambience };
}

export async function analyzeWithOpenAI(
  request: AnalyzeRequest,
  options: { apiKey: string; model: string; catalog?: SoundCatalog; fetcher?: typeof fetch; timeoutMs?: number },
): Promise<AnalyzeResult> {
  const fetcher = options.fetcher ?? fetch;
  const catalog = options.catalog ?? BUNDLED_CATALOG;
  let response: Response;
  try {
    response = await fetcher("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${options.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: options.model,
        messages: [
          { role: "system", content: catalog.systemPrompt },
          { role: "user", content: buildUserMessage(request) },
        ],
        temperature: 0,
        max_tokens: 150,
        response_format: { type: "json_object" },
      }),
      signal: AbortSignal.timeout(options.timeoutMs ?? 5000),
    });
  } catch (error) {
    const timedOut = error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError");
    throw new UpstreamError(timedOut ? "model timed out" : "model unreachable", timedOut ? 504 : 502);
  }

  if (!response.ok) {
    // Upstream rate limits pass through so the app can back off.
    throw new UpstreamError(`model returned ${response.status}`, response.status === 429 ? 429 : 502);
  }

  const json = (await response.json()) as { choices?: { message?: { content?: string } }[] };
  const content = json.choices?.[0]?.message?.content;
  if (typeof content !== "string") throw new UpstreamError("model returned no content", 502);
  return sanitizeResult(content, catalog);
}
