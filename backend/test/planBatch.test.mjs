import { describe, expect, it } from "vitest";
import { batchCredits, knownSoundIds, selectGaps, toBatchEntry } from "../scripts/plan-batch.mjs";

const gap = (id, devices, requests = devices, kind = "oneShot") => ({ id, kind, description: id, devices, requests });

describe("selectGaps", () => {
  it("keeps popular, uncovered gaps, most wanted first", () => {
    const rows = [gap("bee_buzz", 2, 9), gap("witch_cackle", 5), gap("seal_bark", 1), gap("dog_bark", 9), gap("penguin_squeak", 2, 2)];
    const known = new Set(["dog_bark"]);
    expect(selectGaps(rows, known).map((g) => g.id)).toEqual(["witch_cackle", "bee_buzz", "penguin_squeak"]);
    expect(selectGaps(rows, known, { minDevices: 1, limit: 2 }).map((g) => g.id)).toEqual(["witch_cackle", "bee_buzz"]);
  });
});

describe("knownSoundIds", () => {
  it("collects bundled, built and planned ids", () => {
    const ids = knownSoundIds({
      catalogSource: `{ id: "dog_bark", description: "dog" },\n  { id: "storm", description: "storm", ambience: true },`,
      soundLists: [[{ id: "wolf_howl" }], [{ id: "bee_buzz" }, {}], "not a list"],
    });
    expect([...ids].sort()).toEqual(["bee_buzz", "dog_bark", "storm", "wolf_howl"]);
  });
});

describe("toBatchEntry", () => {
  const witch = gap("witch_cackle", 3);

  it("fills in the batch fields and keeps prompts free of music", () => {
    const entry = toBatchEntry(
      { id: "witch_cackle", name: "Witch", category: "animal", description: "a witch cackling", prompt: "A storybook witch cackling", duration: 2.3 },
      witch,
    );
    expect(entry).toEqual({
      id: "witch_cackle", kind: "oneShot", name: "witch", category: "animal",
      description: "a witch cackling", prompt: "A storybook witch cackling. No music.",
      variants: 3, duration: 2.5,
    });
  });

  it("uses the gap's kind, fixes ambience length and clamps one-shots", () => {
    const jungle = gap("jungle_ambience", 2, 2, "ambience");
    const raw = { id: "jungle_ambience", description: "a jungle", prompt: "Jungle birds. No music, no voices.", duration: 8, category: "nope" };
    expect(toBatchEntry(raw, jungle)).toMatchObject({ kind: "ambience", duration: 30, variants: 2, category: "environment" });
    expect(toBatchEntry({ ...raw, id: "witch_cackle" }, witch).duration).toBe(6);
  });

  it("rejects skips, mismatched ids and empty prompts", () => {
    expect(toBatchEntry({ id: "witch_cackle", skip: "duplicate" }, witch)).toBeNull();
    expect(toBatchEntry({ id: "other", description: "x", prompt: "x" }, witch)).toBeNull();
    expect(toBatchEntry({ id: "witch_cackle", description: "x", prompt: " " }, witch)).toBeNull();
    expect(toBatchEntry(undefined, witch)).toBeNull();
  });
});

describe("batchCredits", () => {
  it("counts every variant second", () => {
    expect(batchCredits([{ variants: 3, duration: 2 }, { variants: 2, duration: 30 }])).toBe((6 + 60) * 40);
  });
});
