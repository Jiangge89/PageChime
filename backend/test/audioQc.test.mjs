import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { judge, measure, parseAstats, parseEbur128, parseSilences } from "../scripts/audio-qc.mjs";

const oneShot = { kind: "oneShot", duration: 3 };
const ambience = { kind: "ambience", duration: 30 };
const good = {
  duration: 3, lufs: -20, truePeakDb: -2, peakDb: -2.5, rmsDb: -24, peakCount: 2,
  leadingSilence: 0.05, silenceRatio: 0.1,
};
const codes = (result) => result.issues.map((i) => i.code);

describe("judge", () => {
  it("passes a normal one-shot", () => {
    expect(judge(good, oneShot)).toEqual({ status: "pass", issues: [] });
  });

  it("rejects silent, short and mostly empty takes", () => {
    expect(judge({ ...good, lufs: -Infinity }, oneShot).status).toBe("fail");
    expect(codes(judge({ ...good, lufs: -70 }, oneShot))).toContain("silent");
    expect(codes(judge({ ...good, duration: 1.2 }, oneShot))).toEqual(["too_short"]);
    expect(codes(judge({ ...good, silenceRatio: 0.8 }, oneShot))).toEqual(["mostly_silent"]);
  });

  it("keeps quiet, clipped and late takes with warnings", () => {
    const result = judge({ ...good, lufs: -43, peakDb: 0, peakCount: 40, leadingSilence: 0.9 }, oneShot);
    expect(result.status).toBe("warn");
    expect(codes(result)).toEqual(["quiet", "late_start", "clipping"]);
  });

  it("only checks the loop seam for ambience", () => {
    const seam = { ...good, duration: 30, seamDb: 9 };
    expect(codes(judge(seam, ambience))).toEqual(["loop_seam"]);
    expect(judge({ ...seam, seamDb: 3 }, ambience).status).toBe("pass");
    expect(judge({ ...good, leadingSilence: 2, duration: 30 }, ambience).status).toBe("pass");
  });
});

describe("parsers", () => {
  it("reads the ebur128 summary", () => {
    const stderr = `[Parsed_ebur128_0 @ 0x1] t: 1 M: -30 S: -30 I: -99.0 LUFS
[Parsed_ebur128_0 @ 0x1] Summary:

  Integrated loudness:
    I:         -34.2 LUFS
    Threshold: -44.5 LUFS

  True peak:
    Peak:       -1.1 dBFS`;
    expect(parseEbur128(stderr)).toEqual({ lufs: -34.2, truePeakDb: -1.1 });
    expect(parseEbur128("Summary:\n    I:         -inf LUFS\n    Peak:       -inf dBFS").lufs).toBe(-Infinity);
  });

  it("reads the overall astats block", () => {
    const stderr = `[Parsed_astats_0 @ 0x1] Channel: 1
[Parsed_astats_0 @ 0x1] Peak level dB: -1.000000
[Parsed_astats_0 @ 0x1] RMS level dB: -10.000000
[Parsed_astats_0 @ 0x1] Overall
[Parsed_astats_0 @ 0x1] Peak level dB: -15.468842
[Parsed_astats_0 @ 0x1] RMS level dB: -40.507327
[Parsed_astats_0 @ 0x1] Peak count: 2.000000
[Parsed_astats_0 @ 0x1] Abs Peak count: 1.000000`;
    expect(parseAstats(stderr)).toEqual({ peakDb: -15.468842, rmsDb: -40.507327, peakCount: 2 });
  });

  it("collects silences, including one that runs to the end", () => {
    const stderr = `[silencedetect @ 0x1] silence_start: 0
[silencedetect @ 0x1] silence_end: 0.42 | silence_duration: 0.42
[silencedetect @ 0x1] silence_start: 2.5`;
    expect(parseSilences(stderr, 3)).toEqual([{ start: 0, end: 0.42 }, { start: 2.5, end: 3 }]);
  });
});

describe("measure", () => {
  const dir = mkdtempSync(join(tmpdir(), "audio-qc-"));
  afterAll(() => rmSync(dir, { recursive: true, force: true }));
  const make = (name, filter) => {
    const file = join(dir, name);
    execFileSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", filter, "-ac", "2", file]);
    return file;
  };

  it("passes a tone and rejects silence", () => {
    const tone = measure(make("tone.wav", "sine=frequency=440:duration=3"), "oneShot");
    expect(judge(tone, oneShot).status).toBe("pass");

    const silent = measure(make("silent.wav", "anullsrc=r=44100:cl=stereo:d=3"), "oneShot");
    expect(judge(silent, oneShot).status).toBe("fail");
    expect(silent.silenceRatio).toBeGreaterThan(0.9);
  });

  it("measures a loop seam on ambience", () => {
    // Fades from loud to quiet, so the ends differ a lot.
    const file = make("fade.wav", "sine=frequency=220:duration=10,afade=t=out:st=0:d=10");
    const metrics = measure(file, "ambience");
    expect(metrics.seamDb).toBeGreaterThan(6);
    expect(codes(judge(metrics, { kind: "ambience", duration: 10 }))).toContain("loop_seam");
  });
});
