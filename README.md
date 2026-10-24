# hoot

A pixel-art study buddy for your Mac. Hold ⌃⌥ and ask about whatever you're watching or reading: hoot listens, looks at your screen (and the YouTube transcript), answers out loud, points at the thing, and draws a short animated explainer when a picture helps.

All code in this repository was written during Cal Hacks 13.0 (Oct 24–25, 2026).

Structure:
- `Hoot/` — the macOS app (SwiftUI + AppKit). `xcodegen generate` creates `Hoot.xcodeproj`.
- `worker/` — local API proxy (Cloudflare Workers runtime via `wrangler dev`): LLM, Cartesia TTS, AssemblyAI tokens, YouTube transcripts.
- `studio/` — explainer-video service: script → Cartesia narration → Manim animation → mp4.
- `design/` — pixel pet sources exported from the Claude Design handoff.
