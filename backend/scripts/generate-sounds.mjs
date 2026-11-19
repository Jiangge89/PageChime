#!/usr/bin/env node
/**
 * Generates sound variants with the ElevenLabs Sound Effects API, for review
 * before they go into the cloud library.
 *
 *   node scripts/generate-sounds.mjs <batch.json> [--out <dir>] [--dry-run]
 *       [--only id1,id2] [--max-variants n] [--max-ambience-variants n] [--check-only]
 *
 * --only and the --max flags generate a cheaper subset of the batch into the
 * same folder; a later full run skips what already exists.
 *
 * The batch file lists sounds with a prompt per sound:
 *
 *   [
 *     { "id": "wolf_howl", "kind": "oneShot", "name": "wolf", "category": "animal",
 *       "description": "a lone wolf howling at night",          // what the LLM sees
 *       "prompt": "A lone wolf howling at night in the distance", // what ElevenLabs sees
 *       "variants": 3, "duration": 4 }
 *   ]
 *
 * Output (default library-src/<batch name>/): <id>_<n>.mp3 files, a
 * sounds.json for build-library.mjs, and qc.json with the quality checks.
 *
 * Every variant is checked automatically (see audio-qc.mjs). Variants that
 * fail (silent, cut short, mostly empty) are moved to rejected/ and left out
 * of sounds.json; running again regenerates them. Variants with warnings
 * (very quiet, clipping, audible loop seam, late start) are kept, and
 * review.html lists only those, for an optional listen. --check-only reruns
 * the checks without generating anything.
 *
 * Existing files are skipped, so an interrupted run can be resumed without
 * paying twice. Ambience is requested as a seamless loop.
 *
 * The API key is read from ELEVENLABS_API_KEY or backend/.env.local
 * (ELEVENLABS_API_KEY=...). It is never printed.
 */
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { judge, measure } from "./audio-qc.mjs";

const API_URL = "https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_128";
const MODEL = "eleven_text_to_sound_v3";
const CREDITS_PER_SECOND = 40;
const CONCURRENCY = 3;

const here = dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const args = { batch: null, out: null, dryRun: false, checkOnly: false, only: null, maxVariants: Infinity, maxAmbienceVariants: Infinity };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--out") args.out = argv[++i];
    else if (argv[i] === "--dry-run") args.dryRun = true;
    else if (argv[i] === "--check-only") args.checkOnly = true;
    else if (argv[i] === "--only") args.only = new Set(argv[++i].split(","));
    else if (argv[i] === "--max-variants") args.maxVariants = Number(argv[++i]);
    else if (argv[i] === "--max-ambience-variants") args.maxAmbienceVariants = Number(argv[++i]);
    else if (!args.batch) args.batch = argv[i];
    else throw new Error(`Unknown argument: ${argv[i]}`);
  }
  if (!args.batch) throw new Error("Usage: generate-sounds.mjs <batch.json> [--out dir] [--dry-run]");
  return args;
}

function apiKey() {
  if (process.env.ELEVENLABS_API_KEY) return process.env.ELEVENLABS_API_KEY.trim();
  const envFile = join(here, "..", ".env.local");
  if (existsSync(envFile)) {
    const line = readFileSync(envFile, "utf8").split("\n").find((l) => l.startsWith("ELEVENLABS_API_KEY="));
    if (line) return line.slice("ELEVENLABS_API_KEY=".length).trim();
  }
  return null;
}

function validate(sound, index) {
  const where = `batch[${index}] (${sound.id ?? "?"})`;
  if (!/^[a-z0-9_]{1,64}$/.test(sound.id ?? "")) throw new Error(`${where}: invalid id`);
  if (!["oneShot", "ambience"].includes(sound.kind)) throw new Error(`${where}: kind must be oneShot or ambience`);
  if (!sound.prompt?.trim() || !sound.description?.trim()) throw new Error(`${where}: prompt and description are required`);
  if (!(sound.duration >= 0.5 && sound.duration <= 30)) throw new Error(`${where}: duration must be 0.5-30s`);
  if (!(Number.isInteger(sound.variants) && sound.variants >= 1)) throw new Error(`${where}: variants must be >= 1`);
}

async function generate(key, sound, file) {
  const body = {
    text: sound.prompt,
    model_id: MODEL,
    duration_seconds: sound.duration,
    // Lower influence gives more varied takes across variants.
    prompt_influence: sound.promptInfluence ?? 0.4,
    loop: sound.kind === "ambience",
  };
  let response = await fetch(API_URL, {
    method: "POST",
    headers: { "xi-api-key": key, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (response.status === 422 && body.loop) {
    // In case this model doesn't accept looping; the player crossfades anyway.
    const detail = await response.text();
    console.warn(`  ${sound.id}: loop rejected (${detail.slice(0, 120)}), retrying without loop`);
    response = await fetch(API_URL, {
      method: "POST",
      headers: { "xi-api-key": key, "Content-Type": "application/json" },
      body: JSON.stringify({ ...body, loop: false }),
    });
  }
  if (!response.ok) {
    throw new Error(`${sound.id}: ElevenLabs returned ${response.status}: ${(await response.text()).slice(0, 300)}`);
  }
  writeFileSync(file, Buffer.from(await response.arrayBuffer()));
}

function escapeHtml(text) {
  return text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

/** Lists only the variants with warnings; everything else is kept as is. */
function reviewPage(title, sounds, qc) {
  const flagged = sounds
    .map((s) => ({ ...s, files: s.files.filter((f) => qc[f]?.issues.length) }))
    .filter((s) => s.files.length);
  const cards = flagged
    .map(
      (s) => `
  <section class="sound" data-id="${s.id}">
    <h2>${escapeHtml(s.name)} <code>${s.id}</code> <span class="kind">${s.kind === "ambience" ? "ambience" : "one-shot"}</span></h2>
    <p class="desc">${escapeHtml(s.description)}</p>
    <p class="prompt">Prompt: ${escapeHtml(s.prompt)}</p>
    ${s.files
      .map(
        (f) => `<label class="variant"><input type="checkbox" checked data-file="${f}">
      <audio controls preload="none" ${s.kind === "ambience" ? "loop" : ""} src="${f}"></audio><span>${f}: ${escapeHtml(qc[f].issues.map((i) => i.message).join("; "))}</span></label>`,
      )
      .join("\n    ")}
  </section>`,
    )
    .join("\n");
  const library = JSON.stringify(
    sounds.map(({ id, kind, name, category, description, files }) => ({ id, kind, name, category, description, files })),
  );

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sound Review</title>
<style>
  :root { --bg: #faf7f2; --fg: #2b2620; --muted: #7a6f63; --card: #fff; --line: #e6ddd0; --accent: #c4602b; }
  @media (prefers-color-scheme: dark) { :root { --bg: #1d1a17; --fg: #eee6dc; --muted: #a59a8c; --card: #2a2622; --line: #3d3731; --accent: #e8874f; } }
  body { margin: 0; padding: 24px 16px 96px; background: var(--bg); color: var(--fg); font: 15px/1.5 -apple-system, system-ui, sans-serif; }
  main { max-width: 760px; margin: 0 auto; }
  h1 { margin: 0 0 4px; } .lead { color: var(--muted); margin: 0 0 24px; }
  .sound { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 16px; margin-bottom: 16px; }
  h2 { margin: 0; font-size: 17px; } code { font-size: 13px; color: var(--muted); }
  .kind { font-size: 12px; color: var(--accent); margin-left: 6px; }
  .desc { margin: 4px 0 0; } .prompt { margin: 2px 0 10px; color: var(--muted); font-size: 13px; }
  .variant { display: flex; align-items: center; gap: 10px; margin: 6px 0; flex-wrap: wrap; }
  .variant span { font-size: 12px; color: var(--muted); } audio { height: 36px; max-width: 100%; }
  .bar { position: fixed; left: 0; right: 0; bottom: 0; padding: 12px 16px; background: var(--card); border-top: 1px solid var(--line); text-align: center; }
  button { font: inherit; padding: 8px 18px; border-radius: 8px; border: 0; background: var(--accent); color: #fff; cursor: pointer; }
</style></head>
<body><main>
  <h1>${escapeHtml(title)}</h1>
  <p class="lead">These variants passed the automatic checks with warnings and are kept. Listen if you like, untick any that sound wrong, then export sounds.json. Variants not listed here are kept as they are.</p>
  ${cards}
</main>
<div class="bar"><button id="export">Export sounds.json</button> <span id="count"></span></div>
<script>
  const library = ${library};
  const boxes = [...document.querySelectorAll("input[type=checkbox]")];
  const count = document.getElementById("count");
  const update = () => { count.textContent = boxes.filter((b) => b.checked).length + " of " + boxes.length + " variants kept"; };
  boxes.forEach((b) => b.addEventListener("change", update)); update();
  document.getElementById("export").addEventListener("click", () => {
    const dropped = new Set(boxes.filter((b) => !b.checked).map((b) => b.dataset.file));
    const result = library.map((s) => ({ ...s, files: s.files.filter((f) => !dropped.has(f)) })).filter((s) => s.files.length);
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([JSON.stringify(result, null, 2)], { type: "application/json" }));
    link.download = "sounds.json";
    link.click();
  });
</script></body></html>
`;
}

const args = parseArgs(process.argv.slice(2));
const batchPath = resolve(args.batch);
const fullBatch = JSON.parse(readFileSync(batchPath, "utf8"));
fullBatch.forEach(validate);
if (args.only) {
  const unknown = [...args.only].filter((id) => !fullBatch.some((s) => s.id === id));
  if (unknown.length) throw new Error(`--only: not in batch: ${unknown.join(", ")}`);
}
const batch = fullBatch
  .filter((s) => !args.only || args.only.has(s.id))
  .map((s) => ({
    ...s,
    variants: Math.min(s.variants, s.kind === "ambience" ? args.maxAmbienceVariants : args.maxVariants),
  }));
const batchName = basename(batchPath, ".json");
const outDir = resolve(args.out ?? join(here, "..", "library-src", batchName));

const jobs = batch.flatMap((sound) =>
  Array.from({ length: sound.variants }, (_, n) => ({ sound, file: join(outDir, `${sound.id}_${n + 1}.mp3`) })),
);
const pending = jobs.filter((job) => !existsSync(job.file));
const seconds = pending.reduce((sum, job) => sum + job.sound.duration, 0);
console.log(
  `${batch.length} sounds, ${jobs.length} variants; ${pending.length} to generate ` +
    `(${seconds}s ≈ ${Math.round(seconds * CREDITS_PER_SECOND).toLocaleString()} credits)`,
);

if (args.dryRun) process.exit(0);

mkdirSync(outDir, { recursive: true });
const failures = [];
if (!args.checkOnly && pending.length) {
  const key = apiKey();
  if (!key) {
    console.error("error: set ELEVENLABS_API_KEY or put ELEVENLABS_API_KEY=... in backend/.env.local");
    process.exit(1);
  }
  let next = 0;
  async function worker() {
    while (next < pending.length) {
      const job = pending[next++];
      try {
        await generate(key, job.sound, job.file);
        console.log(`✓ ${basename(job.file)}`);
      } catch (error) {
        failures.push(error.message);
        console.error(`✗ ${error.message}`);
      }
    }
  }
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));
}

// Quality checks: reject failures, keep warnings.
const qc = {};
const counts = { pass: 0, warn: 0, fail: 0 };
for (const job of jobs.filter((j) => existsSync(j.file))) {
  const file = basename(job.file);
  const metrics = measure(job.file, job.sound.kind);
  const result = judge(metrics, job.sound);
  qc[file] = { ...result, metrics };
  counts[result.status]++;
  if (result.status === "pass") continue;
  const note = result.issues.map((i) => i.message).join("; ");
  if (result.status === "fail") {
    mkdirSync(join(outDir, "rejected"), { recursive: true });
    renameSync(job.file, join(outDir, "rejected", file));
    console.warn(`✗ rejected ${file}: ${note}`);
  } else {
    console.warn(`! ${file}: ${note}`);
  }
}
writeFileSync(join(outDir, "qc.json"), JSON.stringify(qc, null, 2));
console.log(
  `\nChecked ${counts.pass + counts.warn + counts.fail} variants: ${counts.pass} passed, ` +
    `${counts.warn} kept with warnings, ${counts.fail} rejected` +
    (counts.fail ? " (run again to regenerate them)" : ""),
);

const sounds = batch.map((s) => ({
  id: s.id,
  kind: s.kind,
  name: s.name ?? s.id.replace(/_/g, " "),
  category: s.category ?? "environment",
  description: s.description,
  prompt: s.prompt,
  files: Array.from({ length: s.variants }, (_, n) => `${s.id}_${n + 1}.mp3`).filter((f) => existsSync(join(outDir, f))),
}));
writeFileSync(
  join(outDir, "sounds.json"),
  JSON.stringify(sounds.filter((s) => s.files.length).map(({ prompt, ...s }) => s), null, 2),
);
const reviewFile = join(outDir, "review.html");
if (counts.warn) {
  writeFileSync(reviewFile, reviewPage(`Sound review: ${batchName}`, sounds.filter((s) => s.files.length), qc));
  console.log(`Optional listen for the warnings: ${reviewFile}`);
} else {
  rmSync(reviewFile, { force: true });
}
console.log(`Ready for build-library.mjs: ${join(outDir, "sounds.json")}`);
if (failures.length) {
  console.error(`${failures.length} variant(s) failed; run again to retry only those.`);
  process.exit(1);
}
