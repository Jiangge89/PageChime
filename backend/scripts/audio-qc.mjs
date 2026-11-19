/**
 * Automatic quality checks for generated sounds, so a batch can go into the
 * library without listening to every variant.
 *
 * measure() runs ffmpeg on one file; judge() turns those numbers into
 * pass / warn / fail. Fails are rejected (silent, cut short, mostly empty);
 * warns are kept but listed, so only odd ones need a listen.
 *
 * Requires ffmpeg and ffprobe on PATH.
 */
import { execFileSync, spawnSync } from "node:child_process";

/** Thresholds, tuned on the first ElevenLabs batch (test-1). */
export const LIMITS = {
  minDuration: 0.4, // seconds
  minDurationRatio: 0.5, // of the requested duration
  silentLufs: -50, // below this the file is effectively empty
  quietLufs: -40, // needs > ~15 dB gain to reach target, noise floor may show
  silence: { noiseDb: -50, minSeconds: 0.3 },
  maxSilenceRatio: { oneShot: 0.6, ambience: 0.5 },
  maxLeadingSilence: 0.5, // one-shots; the build trims it, but long gaps hint at a bad take
  clipPeakDb: -0.1,
  clipPeakCount: 4, // samples at the peak level; a run of them means flat tops
  maxSeamDb: 6, // ambience: loudness difference between the first and last seconds
  seamWindow: 2, // seconds
};

function ffmpegStderr(args) {
  const result = spawnSync("ffmpeg", ["-hide_banner", "-nostats", ...args, "-f", "null", "-"], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(`ffmpeg failed: ${result.stderr.split("\n").slice(-3).join(" ")}`);
  return result.stderr;
}

function probeDuration(file) {
  const out = execFileSync(
    "ffprobe",
    ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", file],
    { encoding: "utf8" },
  );
  return Number(out.trim());
}

const number = (text) => (text === undefined ? null : text === "-inf" ? -Infinity : Number(text));

/** Integrated loudness (LUFS) and true peak (dBFS) from the ebur128 summary. */
export function parseEbur128(stderr) {
  const summary = stderr.slice(stderr.lastIndexOf("Summary:"));
  return {
    lufs: number(summary.match(/I:\s+(-?[\d.]+|-inf)\s+LUFS/)?.[1]),
    truePeakDb: number(summary.match(/Peak:\s+(-?[\d.]+|-inf)\s+dBFS/)?.[1]),
  };
}

/** Overall sample peak, RMS and peak count from astats (the last "Overall" block). */
export function parseAstats(stderr) {
  const overall = stderr.slice(stderr.lastIndexOf("Overall"));
  return {
    peakDb: number(overall.match(/Peak level dB:\s+(-?[\d.]+|-inf)/)?.[1]),
    rmsDb: number(overall.match(/RMS level dB:\s+(-?[\d.]+|-inf)/)?.[1]),
    peakCount: number(overall.match(/\bPeak count:\s+([\d.]+)/)?.[1]),
  };
}

/** Silent stretches from silencedetect; an unterminated one runs to the end. */
export function parseSilences(stderr, duration) {
  const silences = [];
  let start = null;
  for (const line of stderr.split("\n")) {
    const s = line.match(/silence_start:\s+(-?[\d.]+)/);
    if (s) start = Math.max(0, Number(s[1]));
    const e = line.match(/silence_end:\s+([\d.]+)/);
    if (e && start !== null) {
      silences.push({ start, end: Number(e[1]) });
      start = null;
    }
  }
  if (start !== null) silences.push({ start, end: duration });
  return silences;
}

/** Measures one file. Ambience also gets its loop edges compared. */
export function measure(file, kind) {
  const duration = probeDuration(file);
  const { noiseDb, minSeconds } = LIMITS.silence;
  const stderr = ffmpegStderr([
    "-i", file, "-af", `silencedetect=noise=${noiseDb}dB:d=${minSeconds},ebur128=peak=true,astats`,
  ]);
  const silences = parseSilences(stderr, duration);
  const metrics = {
    duration,
    ...parseEbur128(stderr),
    ...parseAstats(stderr),
    leadingSilence: silences[0]?.start === 0 ? silences[0].end : 0,
    silenceRatio: duration > 0 ? silences.reduce((sum, s) => sum + (s.end - s.start), 0) / duration : 1,
  };
  if (kind === "ambience" && duration > LIMITS.seamWindow * 2) {
    const head = parseAstats(ffmpegStderr(["-t", String(LIMITS.seamWindow), "-i", file, "-af", "astats"])).rmsDb;
    const tail = parseAstats(ffmpegStderr(["-sseof", `-${LIMITS.seamWindow}`, "-i", file, "-af", "astats"])).rmsDb;
    metrics.seamDb = Number.isFinite(head) && Number.isFinite(tail) ? Math.abs(head - tail) : null;
  }
  return metrics;
}

const round = (value) => Math.round(value * 10) / 10;

/**
 * Pass, warn or fail for one variant. `sound` is the batch entry
 * ({kind, duration}); `metrics` comes from measure().
 */
export function judge(metrics, sound) {
  const issues = [];
  const fail = (code, message) => issues.push({ level: "fail", code, message });
  const warn = (code, message) => issues.push({ level: "warn", code, message });

  const minDuration = Math.max(LIMITS.minDuration, (sound.duration ?? 0) * LIMITS.minDurationRatio);
  if (!(metrics.duration >= minDuration)) {
    fail("too_short", `${round(metrics.duration)}s long, expected about ${sound.duration}s`);
  }
  if (!(metrics.lufs > LIMITS.silentLufs)) {
    fail("silent", `almost silent (${metrics.lufs} LUFS)`);
  } else if (metrics.lufs < LIMITS.quietLufs) {
    warn("quiet", `very quiet (${metrics.lufs} LUFS); normalizing adds a lot of gain, check the noise floor`);
  }
  const maxSilence = LIMITS.maxSilenceRatio[sound.kind] ?? LIMITS.maxSilenceRatio.oneShot;
  if (metrics.silenceRatio > maxSilence) {
    fail("mostly_silent", `${Math.round(metrics.silenceRatio * 100)}% silence`);
  }
  if (sound.kind === "oneShot" && metrics.leadingSilence > LIMITS.maxLeadingSilence) {
    warn("late_start", `starts after ${round(metrics.leadingSilence)}s of silence`);
  }
  if (metrics.peakDb >= LIMITS.clipPeakDb && metrics.peakCount >= LIMITS.clipPeakCount) {
    warn("clipping", `peaks at full scale ${metrics.peakCount} times, may be distorted`);
  }
  if (sound.kind === "ambience" && metrics.seamDb != null && metrics.seamDb > LIMITS.maxSeamDb) {
    warn("loop_seam", `start and end differ by ${round(metrics.seamDb)} dB, the loop point may be audible`);
  }

  const status = issues.some((i) => i.level === "fail") ? "fail" : issues.length ? "warn" : "pass";
  return { status, issues };
}
