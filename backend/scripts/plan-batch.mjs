#!/usr/bin/env node
/**
 * Turns the most requested sound gaps (sounds stories asked for that the
 * library lacks, logged by the API in D1) into a generation batch for
 * generate-sounds.mjs.
 *
 *   node scripts/plan-batch.mjs [--remote] [--min-devices n] [--limit n]
 *       [--out library/batches/<name>.json] [--dry-run]
 *
 * Reads the gap log from the local D1 (what `npm run dev` writes) unless
 * --remote is given. Gaps already covered by a bundled sound, a library
 * source folder or an earlier batch are skipped. An LLM writes the
 * ElevenLabs prompt, description, category and length for each remaining
 * gap, and drops ones that duplicate an existing sound or don't suit a
 * children's story.
 *
 * The OpenAI key is read from OPENAI_API_KEY or backend/.dev.vars and is
 * never printed.
 */
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const CATEGORIES = ["animal", "weather", "vehicle", "action", "environment", "object"];
const CREDITS_PER_SECOND = 40;

// MARK: - Pure helpers (tested)

/** Gaps worth generating: popular enough, not already covered, most wanted first. */
export function selectGaps(rows, knownIds, { minDevices = 2, limit = 20 } = {}) {
  return rows
    .filter((r) => r.devices >= minDevices && !knownIds.has(r.id))
    .sort((a, b) => b.devices - a.devices || b.requests - a.requests || a.id.localeCompare(b.id))
    .slice(0, limit);
}

/** Every sound id already bundled, in a library source folder, or planned. */
export function knownSoundIds({ catalogSource, soundLists }) {
  const ids = new Set([...catalogSource.matchAll(/id:\s*"([a-z0-9_]+)"/g)].map((m) => m[1]));
  for (const list of soundLists) for (const s of Array.isArray(list) ? list : []) if (s?.id) ids.add(s.id);
  return ids;
}

/**
 * Checks one LLM-written entry against the gap it was written for and fills
 * the fields the batch format needs. Returns null if it's unusable.
 */
export function toBatchEntry(raw, gap) {
  if (!raw || raw.skip || raw.id !== gap.id) return null;
  const kind = gap.kind;
  const prompt = typeof raw.prompt === "string" ? raw.prompt.trim() : "";
  const description = typeof raw.description === "string" ? raw.description.trim() : "";
  if (!prompt || !description) return null;
  const duration = kind === "ambience" ? 30 : Math.min(6, Math.max(1, Number(raw.duration) || 3));
  return {
    id: gap.id,
    kind,
    name: typeof raw.name === "string" && raw.name.trim() ? raw.name.trim().toLowerCase() : gap.id.split("_")[0],
    category: CATEGORIES.includes(raw.category) ? raw.category : "environment",
    description,
    prompt: /no music/i.test(prompt) ? prompt : `${prompt.replace(/\.?$/, ".")} No music.`,
    variants: kind === "ambience" ? 2 : 3,
    duration: Math.round(duration * 2) / 2,
  };
}

export function batchCredits(entries) {
  return entries.reduce((sum, e) => sum + e.variants * e.duration * CREDITS_PER_SECOND, 0);
}

// MARK: - Script

function parseArgs(argv) {
  const args = { remote: false, minDevices: 2, limit: 20, out: null, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--remote") args.remote = true;
    else if (argv[i] === "--min-devices") args.minDevices = Number(argv[++i]);
    else if (argv[i] === "--limit") args.limit = Number(argv[++i]);
    else if (argv[i] === "--out") args.out = argv[++i];
    else if (argv[i] === "--dry-run") args.dryRun = true;
    else throw new Error(`Unknown argument: ${argv[i]}`);
  }
  return args;
}

function openAIKey() {
  if (process.env.OPENAI_API_KEY) return process.env.OPENAI_API_KEY.trim();
  const file = join(root, ".dev.vars");
  const line = existsSync(file) && readFileSync(file, "utf8").split("\n").find((l) => l.startsWith("OPENAI_API_KEY="));
  return line ? line.slice("OPENAI_API_KEY=".length).trim().replace(/^"|"$/g, "") : null;
}

function readGaps(remote) {
  const out = execFileSync(
    "npx",
    [
      "wrangler", "d1", "execute", "pagechime-gaps", remote ? "--remote" : "--local", "--json",
      "--command", "SELECT id, kind, description, requests, devices FROM gaps",
    ],
    { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
  return JSON.parse(out)[0]?.results ?? [];
}

function readJsonFiles(dir, pick) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .map((name) => pick(join(dir, name)))
    .filter((file) => file && existsSync(file))
    .map((file) => JSON.parse(readFileSync(file, "utf8")));
}

const SYSTEM_PROMPT = `You write sound effect prompts for ElevenLabs' text-to-sound model, for a children's storytelling app (ages 3-8) that plays sounds while a parent reads aloud.

For each requested sound return an object:
{"id": same id, "name": one or two lowercase words for the thing making the sound, "category": one of ${CATEGORIES.join(", ")}, "description": what the sound is, under 10 words, for a model that picks sounds (e.g. "a wolf howling at the moon"), "prompt": the ElevenLabs prompt, "duration": seconds}

Prompt style: one or two sentences describing the sound itself, its distance, space and character, storybook rather than realistic-gory, ending with "No music, no voices." (or just "No music." when the sound is itself a voice, like a laugh or a cackle). For ambience, describe a calm, steady bed suitable as a seamless loop with wide stereo. One-shots last 1.5-5 seconds; ambience is 30.

Instead return {"id": ..., "skip": "reason"} when an existing sound listed already covers it (e.g. a garden breeze when there is wind in the trees), it isn't really a sound, or it doesn't suit young children.

Return JSON: {"sounds": [...]}`;

async function writePrompts(gaps, existing, key) {
  const user = `Existing sounds (don't duplicate):\n${existing}\n\nWrite entries for:\n${gaps
    .map((g) => `- ${g.id} (${g.kind}): ${g.description}`)
    .join("\n")}`;
  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: process.env.OPENAI_PLAN_MODEL || "gpt-4o",
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: user },
      ],
      temperature: 0.4,
      response_format: { type: "json_object" },
    }),
  });
  if (!response.ok) throw new Error(`OpenAI returned ${response.status}: ${(await response.text()).slice(0, 200)}`);
  const json = await response.json();
  return JSON.parse(json.choices[0].message.content).sounds ?? [];
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const batchesDir = join(root, "library", "batches");
  const sourcesDir = join(root, "library-src");

  const catalogSource = readFileSync(join(root, "src", "catalog.ts"), "utf8");
  const planned = readJsonFiles(batchesDir, (f) => (f.endsWith(".json") ? f : null));
  const built = readJsonFiles(sourcesDir, (d) => join(d, "sounds.json"));
  const known = knownSoundIds({ catalogSource, soundLists: [...planned, ...built] });

  const rows = readGaps(args.remote);
  const gaps = selectGaps(rows, known, args);
  console.log(`${rows.length} gaps logged; ${gaps.length} to plan (at least ${args.minDevices} devices, not already covered)`);
  for (const g of gaps) console.log(`  ${g.id} (${g.kind}, ${g.devices} devices, ${g.requests} requests): ${g.description}`);
  if (gaps.length === 0 || args.dryRun) return;

  const key = openAIKey();
  if (!key) throw new Error("set OPENAI_API_KEY or put it in backend/.dev.vars");

  const existing = [
    ...[...catalogSource.matchAll(/id:\s*"([a-z0-9_]+)",\s*description:\s*"([^"]+)"/g)].map((m) => `- ${m[1]}: ${m[2]}`),
    ...[...planned, ...built].flat().map((s) => `- ${s.id}: ${s.description}`),
  ].join("\n");
  const written = await writePrompts(gaps, existing, key);

  const entries = [];
  for (const gap of gaps) {
    const raw = written.find((w) => w?.id === gap.id);
    const entry = toBatchEntry(raw, gap);
    if (entry) entries.push(entry);
    else console.log(`  skipped ${gap.id}: ${raw?.skip ?? "no usable prompt"}`);
  }
  if (entries.length === 0) return console.log("Nothing to generate.");

  const out = resolve(args.out ?? join(batchesDir, `gaps-${new Date().toISOString().slice(0, 10)}.json`));
  if (existsSync(out)) throw new Error(`${relative(process.cwd(), out)} exists; pass --out`);
  writeFileSync(out, JSON.stringify(entries, null, 2) + "\n");

  const rel = relative(root, out);
  console.log(
    `\nWrote ${entries.length} sounds to ${rel} (≈ ${batchCredits(entries).toLocaleString()} ElevenLabs credits). Next:\n` +
      `  node scripts/generate-sounds.mjs ${rel}\n` +
      `  node scripts/build-library.mjs library-src/* --upload local`,
  );
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(`error: ${error.message}`);
    process.exit(1);
  });
}
