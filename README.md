# hoot

A pixel-art study buddy for your Mac. Hold ⌃⌥ and ask about whatever you're watching or reading: hoot listens, looks at your screen (and the YouTube transcript), answers out loud, points at the thing, and draws a short animated explainer when a picture helps.

All code in this repository was written during Cal Hacks 13.0 (Oct 24–25, 2026).

Structure:
- `Hoot/` — the macOS app (SwiftUI + AppKit). `xcodegen generate` creates `Hoot.xcodeproj`.
- `worker/` — local API proxy (Cloudflare Workers runtime via `wrangler dev`): LLM, Cartesia TTS, AssemblyAI tokens, YouTube transcripts.
- `studio/` — explainer-video service: script → Cartesia narration → Manim animation → mp4.
- `design/` — pixel pet sources exported from the Claude Design handoff.

## Brain

hoot thinks with Claude. The app speaks the Anthropic Messages API directly (`Hoot/Sources/Platform/LLMClient.swift`): every question goes out as one streamed request with the screenshots of all screens as image blocks, the tutor system prompt (`HootTutorPrompt.swift`), the conversation so far, and the YouTube transcript window; the reply streams back and is spoken sentence by sentence while it is still being written. The model picker in settings offers Claude Sonnet 5.5 (default) and Claude Opus 5.5. The worker's `POST /chat` forwards the body to Anthropic untouched and streams the SSE back; set `ANTHROPIC_API_KEY` in `worker/.dev.vars`.

For development without an Anthropic key, `BRAIN=openai` in `worker/.dev.vars` makes the worker translate the same Anthropic-format request to OpenAI Chat Completions and answer in Anthropic's SSE shape, so the app is unchanged. The demo video was recorded on that fallback.

Where the model can go wrong, and what hoot does about it: it can misread what is on screen or the transcript, so the prompt tells it to say when it isn't sure, to point at things rather than describe them, and never to invent screen content; a mis-aimed `[POINT:]` box is a visible, correctable mistake rather than a silent one. A wrong rewind only moves the video, which the learner sees and can undo. "Just do it" clicks only after the learner says so out loud, stops the instant they touch the mouse, and never types. Memory stays on the Mac and can be wiped from the panel.

## Voices

hoot speaks through the worker's `POST /tts`, which returns one mp3 clip per sentence from one of two providers:

- **Cartesia** (default, the live voice): `sonic-3.6`, voices `warm professor` / `calm explainer` / `bright guide` / `british storyteller`, speed 0.6–1.5×. Needs `CARTESIA_API_KEY` in `worker/.dev.vars`.
- **ElevenLabs** (switchable): `eleven_v4` (their best-sounding model; hoot still speaks sentence by sentence while the answer streams, so the extra latency per clip is small), `mp3_44100_128` output, speed mapped to `voice_settings.speed` (clamped to ElevenLabs' 0.7–1.2). Needs `ELEVENLABS_API_KEY` in `worker/.dev.vars`. The picker's voices come from `GET /tts/voices?provider=elevenlabs`, a curated list of library voices the app never needs a key for: `clear educator` (Alice), `warm storyteller` (George), `upbeat professional` (Matilda), `relaxed narrator` (River).

Switch in the menu bar panel: settings → voice → `cartesia | elevenlabs`, then pick a voice and press play to preview. The choice is saved in UserDefaults (`WaitWhatVoiceSettings.swift`) and sent as `provider` + `voice_id` with every `/tts` request (`CartesiaTTSClient.swift`).

Explainer videos follow the same setting: the app sends `ttsProvider` with `POST /explain`, and the studio narrates the beats with that provider (`studio/src/pipeline/voice.ts`). Without the field the studio uses `STUDIO_TTS_PROVIDER` (`cartesia` unless set to `elevenlabs`; `ELEVENLABS_VOICE_ID` picks the narrator, default Alice). The studio reads env at startup, so restart it after changing those.
