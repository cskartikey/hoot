# hoot — notes for Claude

hoot is a macOS menu-bar study buddy built at **Cal Hacks 13.0** (submission deadline **Sun Oct 25, 9:00am PDT** on Devpost; judging 10:30am). Hold ⌃⌥ and ask about whatever is on screen: hoot (a pixel-art owl) listens, sees the screen + the YouTube transcript, answers out loud with Cartesia, points at the thing with an index-card frame, and asks the studio for a narrated Manim explainer video when a picture helps.

## Hard rules
- **All code must be written during the event.** No code from other projects or earlier repos. Don't copy from `~/sideprojects/calhacks` (an earlier prototype) or any open-source app; write fresh. Keep the git history clean.
- Never commit secrets: keys live in `worker/.dev.vars` (gitignored). Never print their values.
- Don't run `xcodebuild` against the user's signed build. To compile-check: `xcodegen generate && xcodebuild -project Hoot.xcodeproj -scheme Hoot -configuration Debug -derivedDataPath /tmp/hoot-dd CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"`. The user runs the app with ⌘R in Xcode. Never launch the app yourself.
- After adding/removing Swift files, run `xcodegen generate` (project is generated from `project.yml`).

## Layout
- `Hoot/Sources/Core/` — `HootController` (coordinator: push-to-talk → screenshot → LLM stream → sentence-by-sentence Cartesia speech, `[VIDEO:]`, `[POINT:x,y,w,h:label]`, YouTube pause/context/resume, recent questions), `HootTutorPrompt`, `HootResponseTags`, `HootApp` (delegate + wiring), `MenuBarController` (status item + panel; resizes are applied async — sync resizing crashed with "more Update Constraints in Window passes").
- `Hoot/Sources/Input/` — ⌃⌥ key monitor, mic, AssemblyAI v3 streaming (auto end-of-turn while held: `min_turn_silence=700`, `max_turn_silence=2000`).
- `Hoot/Sources/Platform/` — `ScreenCapturer`, `PermissionCenter`, `LLMClient` (25s first-byte / 20s stall timeouts).
- `Hoot/Sources/UI/` — overlay (design "4a": hoot dozes in the bottom-right corner, zips to the cursor as a 12×12 head when asked, linger 3s, flies home; `PetPointingFrame` = index-card frame + tab), menu panel (onboarding → home ⇄ settings).
- `Hoot/Sources/*.swift` — theme (`WaitWhatTheme`: tokens, mascots hoot/lotl/bit, `PetSpriteView`, fonts), explainer panel (+ buddies-play-catch loading scene, big-window player), `StudioClient`, `YouTubeContextProvider`, `CartesiaTTSClient` (sentence queue), `RecentQuestionsStore`, `WaitWhatVoiceSettings`.
- `Hoot/Resources/` — JetBrains Mono (OFL), `Pets/*.json` sprites (exported by `design/crisp/export-sprites.cjs` from `pets.js`), app icon (`design/crisp/make-app-icon.py`).
- `worker/` — local API on :8787 (`npx wrangler dev --port 8787`): `/chat` (Anthropic, or OpenAI when `BRAIN=openai`), `/tts` (Cartesia sonic-3.6, `voice_id`, `speed`), `/transcribe-token` (AssemblyAI), `GET /youtube/:id/transcript`.
- `studio/` — explainer videos on :7777 (`pnpm start`; log `studio/out/server.log`): script → Cartesia narration → Manim scene (LLM) → render (fix-retry, fallback) → ffmpeg. Outputs in `studio/out/<job>/`. No LaTeX on this Mac (kit uses Unicode text).

## Design
Claude Design project `286d4c78-b5ca-45ef-81a2-7406b0b3e63f` (read with the claude_design MCP): `design_handoff_wait_what/README.md` (tokens, screens), `POINTING.md` (frame 1b), `wait what Cursor.dc.html` (4a behaviour). Light + dark everywhere; colors only from `WaitWhatThemeStore.shared.theme`.

## Status / open items (as of Sat Oct 24 afternoon)
- Brain is OpenAI (`gpt-6.1-sol`) until an Anthropic key is added to `worker/.dev.vars` (then remove `BRAIN=openai`). Prizes targeted: Anthropic, Cartesia, Best Solo.
- Not built: memory ("hoot remembers" concepts across sessions), corner nudges, reopening a recent question's saved video.
- Overlay restyle (speech bubbles etc.) may come as another Claude Design handoff.
- AssemblyAI may refuse with "too many concurrent sessions" if another app uses the same key.

## Style
Very explicit, long descriptive names; comments explain why; `@MainActor` by default (Swift 5 mode, `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`); `.pointerCursor()` on clickable things. Commit messages end with the Co-Authored-By line given by the harness.
