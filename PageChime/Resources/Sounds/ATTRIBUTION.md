# Sound Assets

All 58 sound files in this directory were generated for PageChime with the
[ElevenLabs Sound Effects API](https://elevenlabs.io/sound-effects) and are
used under the ElevenLabs terms for paid plans, which allow commercial use.

Each file is the first variant of the matching sound in the cloud library
(`backend/library/batches/bundled-1.json`, `ambience-1.json` and
`test-1.json` hold the prompts), loudness-normalized by
`backend/scripts/build-library.mjs`. The app plays this copy at once and
downloads the other variants from the library for variety.

The files that were here before (of unclear origin) have been replaced.
