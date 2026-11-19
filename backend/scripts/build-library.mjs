#!/usr/bin/env node
/**
 * Builds the cloud sound library from a source folder and optionally uploads
 * it to R2.
 *
 *   node scripts/build-library.mjs <source-dir> [--out <dir>] [--upload local|remote] [--bucket <name>]
 *
 * <source-dir>/sounds.json lists the sounds; audio files sit next to it:
 *
 *   [
 *     {
 *       "id": "wolf_howl",            // lowercase, digits, underscores
 *       "kind": "oneShot",            // or "ambience"
 *       "name": "wolf",               // short display name
 *       "category": "animal",         // animal|weather|vehicle|action|environment|object
 *       "description": "a lone wolf howling at night",   // what the LLM sees
 *       "files": ["wolf_howl_1.wav", "wolf_howl_2.wav"]  // variants, any format ffmpeg reads
 *     }
 *   ]
 *
 * Each file is converted to 44.1 kHz stereo AAC, loudness-normalized
 * (one-shots -18 LUFS, ambience -26 LUFS so beds sit under the reader's
 * voice), and one-shots have leading silence trimmed so they start
 * instantly. Output files are named by content hash, so they can be cached
 * forever. The manifest is uploaded last, so clients never see a manifest
 * that points at files not yet uploaded.
 *
 * Requires ffmpeg and ffprobe on PATH.
 */
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const ID_PATTERN = /^[a-z0-9_]{1,64}$/;
const CATEGORIES = new Set(["animal", "weather", "vehicle", "action", "environment", "object"]);

function parseArgs(argv) {
  const args = { source: null, out: "library-dist", upload: null, bucket: "pagechime-sounds" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--out") args.out = argv[++i];
    else if (arg === "--upload") args.upload = argv[++i];
    else if (arg === "--bucket") args.bucket = argv[++i];
    else if (!arg.startsWith("--") && !args.source) args.source = arg;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!args.source) throw new Error("Usage: build-library.mjs <source-dir> [--out dir] [--upload local|remote]");
  if (args.upload && !["local", "remote"].includes(args.upload)) throw new Error("--upload must be local or remote");
  return args;
}

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

function validateEntry(entry, index) {
  const where = `sounds.json[${index}]`;
  if (!ID_PATTERN.test(entry.id ?? "")) fail(`${where}: invalid id "${entry.id}"`);
  if (!["oneShot", "ambience"].includes(entry.kind)) fail(`${where} (${entry.id}): kind must be oneShot or ambience`);
  if (!entry.description?.trim()) fail(`${where} (${entry.id}): description is required`);
  if (entry.category && !CATEGORIES.has(entry.category)) fail(`${where} (${entry.id}): unknown category`);
  if (!Array.isArray(entry.files) || entry.files.length === 0) fail(`${where} (${entry.id}): files is empty`);
}

function convert(input, output, kind) {
  const filters =
    kind === "oneShot"
      ? ["silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.02", "loudnorm=I=-18:TP=-1.5:LRA=11"]
      : ["loudnorm=I=-26:TP=-2:LRA=7"];
  execFileSync(
    "ffmpeg",
    [
      "-hide_banner", "-loglevel", "error", "-y",
      "-i", input,
      "-af", filters.join(","),
      "-ac", "2", "-ar", "44100",
      "-c:a", "aac", "-b:a", kind === "oneShot" ? "128k" : "160k",
      "-movflags", "+faststart",
      output,
    ],
    { stdio: ["ignore", "inherit", "inherit"] },
  );
}

function duration(file) {
  const out = execFileSync(
    "ffprobe",
    ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", file],
    { encoding: "utf8" },
  );
  return Math.round(Number(out.trim()) * 100) / 100;
}

function wrangler(args) {
  execFileSync("npx", ["wrangler", ...args], { stdio: ["ignore", "inherit", "inherit"] });
}

const args = parseArgs(process.argv.slice(2));
const sourceDir = resolve(args.source);
const outDir = resolve(args.out);
const entries = JSON.parse(readFileSync(join(sourceDir, "sounds.json"), "utf8"));
if (!Array.isArray(entries)) fail("sounds.json must be an array");

rmSync(outDir, { recursive: true, force: true });
mkdirSync(join(outDir, "sounds"), { recursive: true });

const seen = new Set();
const sounds = [];
for (const [index, entry] of entries.entries()) {
  validateEntry(entry, index);
  if (seen.has(entry.id)) fail(`duplicate id ${entry.id}`);
  seen.add(entry.id);

  const variants = [];
  for (const [n, file] of entry.files.entries()) {
    const temp = join(outDir, `tmp-${entry.id}-${n}.m4a`);
    convert(join(sourceDir, file), temp, entry.kind);
    const hash = createHash("sha256").update(readFileSync(temp)).digest("hex").slice(0, 10);
    const name = `${entry.id}.${hash}.m4a`;
    renameSync(temp, join(outDir, "sounds", name));
    variants.push({ file: name, duration: duration(join(outDir, "sounds", name)), bytes: statSync(join(outDir, "sounds", name)).size });
  }

  sounds.push({
    id: entry.id,
    kind: entry.kind,
    name: entry.name ?? entry.id.replace(/_/g, " "),
    category: entry.category ?? "environment",
    description: entry.description.trim(),
    variants,
  });
  console.log(`✓ ${entry.id} (${entry.kind}, ${variants.length} variant${variants.length === 1 ? "" : "s"})`);
}

const manifest = { version: Math.floor(Date.now() / 1000), sounds };
writeFileSync(join(outDir, "library.json"), JSON.stringify(manifest, null, 2));
const totalBytes = sounds.flatMap((s) => s.variants).reduce((sum, v) => sum + v.bytes, 0);
console.log(`Built ${sounds.length} sounds, ${(totalBytes / 1e6).toFixed(1)} MB → ${outDir}`);

if (args.upload) {
  const where = `--${args.upload}`;
  for (const variant of sounds.flatMap((s) => s.variants)) {
    wrangler(["r2", "object", "put", `${args.bucket}/sounds/${variant.file}`, "--file", join(outDir, "sounds", variant.file), "--content-type", "audio/mp4", where]);
  }
  wrangler(["r2", "object", "put", `${args.bucket}/library.json`, "--file", join(outDir, "library.json"), "--content-type", "application/json", where]);
  console.log(`Uploaded to ${args.bucket} (${args.upload})`);
}
