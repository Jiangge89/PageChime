/**
 * The cloud sound library: a manifest (`library.json`) plus audio files under
 * `sounds/` in an R2 bucket. Files are content-hashed, so they never change
 * once published and can be cached forever.
 */
import { CATALOG, type CatalogSound } from "./catalog";

export const MANIFEST_KEY = "library.json";
export const SOUND_PREFIX = "sounds/";

export type SoundKind = "oneShot" | "ambience";

export interface LibraryVariant {
  file: string;
  /** Seconds. */
  duration: number;
  bytes: number;
}

export interface LibrarySound {
  id: string;
  kind: SoundKind;
  /** Short display name, e.g. "wolf". */
  name: string;
  /** What the sound is, for the LLM, e.g. "a lone wolf howling at night". */
  description: string;
  /** One of the app's StoryEventType values; used for the icon. */
  category: string;
  variants: LibraryVariant[];
}

export interface LibraryManifest {
  version: number;
  sounds: LibrarySound[];
}

/** Subset of an R2 object we use. */
export interface StoredObject {
  body: ReadableStream | null;
  size: number;
  httpEtag: string;
  text(): Promise<string>;
}

/** Subset of an R2 bucket we use. */
export interface ObjectStore {
  get(key: string): Promise<StoredObject | null>;
}

const ID_PATTERN = /^[a-z0-9_]{1,64}$/;
export const FILE_PATTERN = /^[A-Za-z0-9_-]{1,64}\.[A-Za-z0-9]{1,16}\.m4a$/;
const CATEGORIES = new Set(["animal", "weather", "vehicle", "action", "environment", "object"]);

/** Keeps only well-formed entries, so one bad edit can't break every client. */
export function validateManifest(raw: unknown): LibraryManifest {
  const object = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  const sounds: LibrarySound[] = [];
  const seen = new Set<string>();

  for (const item of Array.isArray(object.sounds) ? object.sounds : []) {
    if (typeof item !== "object" || item === null) continue;
    const s = item as Record<string, unknown>;
    if (typeof s.id !== "string" || !ID_PATTERN.test(s.id) || seen.has(s.id)) continue;
    if (s.kind !== "oneShot" && s.kind !== "ambience") continue;
    if (typeof s.description !== "string" || !s.description.trim()) continue;

    const variants: LibraryVariant[] = [];
    for (const v of Array.isArray(s.variants) ? s.variants : []) {
      if (typeof v !== "object" || v === null) continue;
      const { file, duration, bytes } = v as Record<string, unknown>;
      if (typeof file !== "string" || !FILE_PATTERN.test(file)) continue;
      if (typeof duration !== "number" || !(duration > 0) || typeof bytes !== "number" || !(bytes > 0)) continue;
      variants.push({ file, duration, bytes });
    }
    if (variants.length === 0) continue;

    seen.add(s.id);
    sounds.push({
      id: s.id,
      kind: s.kind,
      name: typeof s.name === "string" && s.name.trim() ? s.name.trim().slice(0, 40) : s.id.replace(/_/g, " "),
      description: s.description.trim().slice(0, 200),
      category: typeof s.category === "string" && CATEGORIES.has(s.category) ? s.category : "environment",
      variants,
    });
  }

  const version = typeof object.version === "number" && Number.isFinite(object.version) ? object.version : 0;
  return { version, sounds };
}

export const EMPTY_MANIFEST: LibraryManifest = { version: 0, sounds: [] };

interface CachedManifest {
  manifest: LibraryManifest;
  etag: string | null;
  json: string;
  loadedAt: number;
}

let cached: CachedManifest | null = null;
const MANIFEST_TTL_MS = 60_000;

/** Loads the manifest, cached per isolate for a minute. */
export async function loadManifest(store: ObjectStore | undefined, now = Date.now()): Promise<CachedManifest> {
  if (cached && now - cached.loadedAt < MANIFEST_TTL_MS) return cached;
  let manifest = EMPTY_MANIFEST;
  let etag: string | null = null;
  const object = store ? await store.get(MANIFEST_KEY) : null;
  if (object) {
    try {
      manifest = validateManifest(JSON.parse(await object.text()));
      etag = object.httpEtag;
    } catch {
      console.warn("library.json is not valid JSON; serving an empty library");
    }
  }
  cached = { manifest, etag, json: JSON.stringify(manifest), loadedAt: now };
  return cached;
}

export function resetManifestCache() {
  cached = null;
}

/**
 * The sounds the LLM may choose from: the sounds bundled in the app, plus
 * library sounds. A library sound with a bundled ID keeps the bundled entry
 * (the app already knows it) but gains cloud variants on the client.
 */
export function mergedCatalog(manifest: LibraryManifest): CatalogSound[] {
  const bundled = new Set(CATALOG.map((s) => s.id));
  const extra = manifest.sounds
    .filter((s) => !bundled.has(s.id))
    .map((s) => ({ id: s.id, description: s.description, ambience: s.kind === "ambience" }));
  return [...CATALOG, ...extra];
}
