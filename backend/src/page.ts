/**
 * Whole-page analysis: the app photographs a book page, reads its text on
 * device, and sends it here before the parent reads it aloud. The model
 * returns every sound cue on the page with the phrase that sets it off, so
 * the app can play each one the moment that phrase is heard, with no network
 * wait, and download the page's sounds in advance.
 */
import {
  catalogSection,
  completeJSON,
  parseMissing,
  SoundCatalog,
  UpstreamError,
  type OpenAIOptions,
  type SoundMatch,
} from "./analyze";
import type { SoundGap } from "./gaps";

export const MAX_PAGE_LENGTH = 4000;
const MAX_PAGE_CONTEXT = 1000;
const MAX_CUES = 16;
const MAX_AMBIENCE = 3;
const MAX_UPCOMING = 8;
const MAX_TRIGGER = 80;

export interface PageRequest {
  text: string;
  /** The story read before this page, if any. */
  context: string;
}

export interface PageResult {
  /** One-shots and mid-page ambience changes, in reading order. */
  cues: SoundMatch[];
  /** Ambience at the top of the page, or null to keep the current scene. */
  ambience: string[] | null;
  /** Sounds likely on the following pages. */
  upcoming: string[];
}

export interface PageAnalysis extends PageResult {
  missing: SoundGap[];
}

const pagePrompts = new WeakMap<SoundCatalog, string>();

function pagePrompt(catalog: SoundCatalog): string {
  let prompt = pagePrompts.get(catalog);
  if (!prompt) {
    prompt = `You add sound effects to a children's picture book that a parent is about to read aloud. You receive the text of one page (read from a photo, so expect line breaks and the odd recognition error) and, if any, the story before it.

One-shot sounds:
${catalogSection(catalog.sounds, false)}

Ambience beds (looping background):
${catalogSection(catalog.sounds, true)}

Return JSON: {"cues": [{"id": "sound_id", "trigger": "phrase"}], "ambience": ["sound_id"] or null, "upcoming": ["sound_id"], "missing": [{"id": "new_sound_id", "kind": "oneShot" or "ambience", "description": "..."}]}

Rules:
- "cues": in reading order, one per sound event the page describes happening (not negated, not hypothetical), at most ${MAX_CUES}. An ambience id may be a cue where the setting changes partway down the page.
- "trigger": 2-5 consecutive words copied exactly from the page, ending on the word where the sound should start (e.g. "the wolf howled"). Pick words unlikely to appear earlier on the page.
- "ambience": 0-${MAX_AMBIENCE} ambience ids for the setting at the top of the page; null if the page doesn't say.
- "upcoming": 0-${MAX_UPCOMING} ids the following pages will probably need (characters and places in the story, later scenes of a tale you recognise).
- "missing": at most 2 sounds the page clearly calls for that no id fits, with a short new snake_case id and a short English description.
- Leave out keys that would be empty. Apart from "missing", only use ids from the lists above.`;
    pagePrompts.set(catalog, prompt);
  }
  return prompt;
}

export function parsePageRequest(body: unknown): PageRequest | null {
  if (typeof body !== "object" || body === null) return null;
  const { text, context } = body as Record<string, unknown>;
  if (typeof text !== "string" || text.trim().length === 0) return null;
  if (context !== undefined && typeof context !== "string") return null;
  return { text: text.slice(0, MAX_PAGE_LENGTH), context: (context ?? "").slice(-MAX_PAGE_CONTEXT) };
}

/** Lowercased letters and digits only, so OCR line breaks and punctuation don't matter. */
function squash(text: string): string {
  return text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "");
}

/** Keeps known sounds whose trigger really is on the page. */
export function sanitizePage(content: string, page: string, catalog: SoundCatalog): PageAnalysis {
  let parsed: unknown;
  try {
    parsed = JSON.parse(content);
  } catch {
    throw new UpstreamError("model returned invalid JSON", 502);
  }
  const object = (typeof parsed === "object" && parsed !== null ? parsed : {}) as Record<string, unknown>;
  const pageText = squash(page);

  const cues: SoundMatch[] = [];
  for (const item of Array.isArray(object.cues) ? object.cues : []) {
    if (typeof item !== "object" || item === null) continue;
    const { id, trigger } = item as Record<string, unknown>;
    if (typeof id !== "string" || typeof trigger !== "string" || !catalog.has(id)) continue;
    const phrase = trigger.trim().slice(0, MAX_TRIGGER);
    const squashed = squash(phrase);
    // A trigger that isn't on the page would never be heard.
    if (squashed.length < 2 || !pageText.includes(squashed)) continue;
    cues.push({ id, trigger: phrase });
    if (cues.length === MAX_CUES) break;
  }

  const ids = (value: unknown, allowed: (id: string) => boolean, max: number) =>
    Array.isArray(value)
      ? [...new Set(value.filter((id): id is string => typeof id === "string" && allowed(id)))].slice(0, max)
      : [];
  const ambience = Array.isArray(object.ambience) ? ids(object.ambience, (id) => catalog.ambienceIds.has(id), MAX_AMBIENCE) : null;
  const onPage = new Set([...cues.map((c) => c.id), ...(ambience ?? [])]);
  const upcoming = ids(object.upcoming, (id) => catalog.has(id) && !onPage.has(id), MAX_UPCOMING);

  return { cues, ambience, upcoming, missing: parseMissing(object.missing, catalog) };
}

export async function analyzePageWithOpenAI(
  request: PageRequest,
  options: OpenAIOptions & { catalog: SoundCatalog },
): Promise<PageAnalysis> {
  const user = request.context ? `Story so far: ${request.context}\n\nPage: ${request.text}` : `Page: ${request.text}`;
  const content = await completeJSON(pagePrompt(options.catalog), user, {
    ...options,
    maxTokens: 700,
    // Runs before reading starts, so it can take longer than live analysis.
    timeoutMs: options.timeoutMs ?? 15000,
    label: "page",
  });
  return sanitizePage(content, request.text, options.catalog);
}
