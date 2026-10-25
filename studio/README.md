# studio

Turns a learner's question into a 20-45 second narrated Manim animation. The macOS app calls it when the tutor emits `[VIDEO:brief]`.

```
POST /explain → script (LLM, 3-6 beats) → Cartesia TTS per beat (parallel) → LLM writes a Manim scene
→ render 720p30 (up to 2 LLM fixes on error) → fallback slides scene if all else fails → ffmpeg mux → mp4
```

A typical job takes 35-55 s end to end (script ~10 s, voice ~1 s, scene code ~20-30 s, render ~5 s, mux ~1 s).

## Run

Needs Node 22+, pnpm, [uv](https://docs.astral.sh/uv/), ffmpeg/ffprobe, and Cairo/Pango (`brew install pkg-config cairo pango`). LaTeX (MacTeX, `latex` + `dvisvgm`) is optional: with it, `tex()` / `MathTex` typeset real fractions, sums and matrices; without it the kit draws all math as Unicode text and swaps MathTex/Tex for Text-based stand-ins.

```sh
cd studio
pnpm install
pnpm setup:manim  # uv sync: Manim into manim/.venv
pnpm start        # http://localhost:7777  (pnpm dev = restart on change)
```

To leave it running in the background:

```sh
mkdir -p out && nohup pnpm start > out/server.log 2>&1 &
```

On start it renders a tiny scene to warm Manim, Cairo and the fonts (`/health` shows `"warm":"ready"`).

## Environment

Read at startup from the process env, then `studio/.env`, then the repo's `worker/.dev.vars` (first one wins). Keys are never logged.

| var | default | |
|---|---|---|
| `BRAIN` (or `STUDIO_BRAIN`) | `openai` | `openai` or `anthropic` |
| `OPENAI_API_KEY`, `OPENAI_MODEL` | `gpt-6.1-sol` | Chat Completions with `reasoning_effort` |
| `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` | `claude-opus-5-5` | Messages API, adaptive thinking |
| `CARTESIA_API_KEY`, `CARTESIA_VOICE_ID` | | Sonic 3.6, same voice as the app |
| `STUDIO_TTS_PROVIDER` | `cartesia` | `cartesia` or `elevenlabs`; a `ttsProvider` field in the `/explain` body overrides it per job |
| `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID` | Alice (`Xb7hH8MSUJpSbSDYk0k2`) | Flash v2.5 narration when the provider is `elevenlabs` |
| `MOSS_PROJECT_ID`, `MOSS_PROJECT_KEY` | | Moss memory search (optional; see "Moss") |
| `MOSS_MEMORY_INDEX` | `hoot-memory` | Moss index / session name |
| `STUDIO_PORT` | `7777` | |
| `STUDIO_PUBLIC_URL` | `http://localhost:7777` | base of the `url` in `done` |

## API

### `POST /explain`
```json
{ "question": "why does det = 0 squish space?",
  "brief": "Show a 2D grid; …",
  "spokenAnswer": "Okay, look at this grid…",
  "context": { "app": "Google Chrome",
               "youtube": { "videoId": "…", "title": "…", "t": 412.3, "transcriptWindow": "…" },
               "screenText": "…" },
  "memory": [{ "concept": "linear transformation", "summary": "…" }] }
```
Only `question` is required. An optional `"ttsProvider": "elevenlabs"` narrates this job with ElevenLabs (see Environment). Returns `{"jobId":"abc123"}` immediately.

### `GET /jobs/:id/events` (Server-Sent Events)
Replays everything so far, then streams until `done` or `error`, then closes.
```
event: stage   data: {"stage":"script","label":"Writing the explanation"}
event: script  data: {"title":"…","beats":[{"id":1,"narration":"…","visual":"…"}]}
event: stage   data: {"stage":"voice","label":"Recording narration"}
event: stage   data: {"stage":"render","label":"Animating","attempt":1}
event: stage   data: {"stage":"render","label":"Fixing animation","attempt":2}      (only on a failed render)
event: done    data: {"url":"http://localhost:7777/jobs/abc123/video.mp4","duration":31.2,
                      "captions":[{"start":0.3,"end":2.1,"text":"…"}],"fallback":false}
event: error   data: {"message":"…"}
```
`captions` are sentence-level, timed to where each beat's audio actually sits in the video. `fallback: true` means the animated-text fallback was used.

### `GET /jobs/:id/video.mp4`
H.264 High / yuv420p / AAC 44.1 kHz, `+faststart`, 1280x720 30 fps. Supports `Range` (AVPlayer needs it). 409 while not ready.

### `GET /jobs/:id`
Debug summary: outcome (`first` / `fixed` / `fallback`), timings, errors, events.

### `GET /health`
`{"ok":true,"warm":"ready","brain":"openai","model":"…","openai":true,"anthropic":false,"cartesia":true}`

## Moss (memory search)

hoot remembers what the learner got stuck on (`memory.json` in the app). The studio mirrors those memories into [Moss](https://moss.dev) so recall ranks them by meaning: Apple's on-device sentence embedding couldn't tell technical topics apart ("det 0 in 3d" scored closer to a *variance* memory than to the *determinant* one), so the app had to blend it with keyword overlap. Code: `src/memory/moss.ts`, app side `Hoot/Sources/Memory/MossMemorySearch.swift`.

How it uses Moss (`@moss-js/moss`, model `moss-mediumlm`):

- **On start:** `client.session('hoot-memory', 'moss-mediumlm')` then `session.loadIndex('hoot-memory')` pulls the cloud copy in without re-embedding.
- **New memory:** `session.addDocs([...], { upsert: true })`: embedded in-process, queryable right away.
- **Recall:** `session.query(text, { topK, alpha })` in memory (a few ms). The app sends the question, the video title and the last transcript lines; each is queried on its own and a memory keeps its best score.
- **Persist:** `session.pushIndex()` 30 s after the last change and on SIGTERM/SIGINT. A push replaces the cloud index, so it only happens once the cloud copy was loaded (a failed load means local-only, no push).
- **Forget everything:** deletes the session's docs and `client.deleteIndex('hoot-memory')`.

Without credentials every route answers `{"enabled":false}` immediately and the app uses its on-device blend. The app also falls back when the studio is down or a query takes over 400 ms, and on launch it backfills Moss if Moss holds fewer memories than `memory.json`.

Free tier: the Developer plan allows 3 indexes, and local queries are never metered. Session time is metered (60 min/month free; Cal Hacks credits via code `CALHACKS` on the portal billing page). We don't use `autoRefresh`, because every poll counts as session time.

| route | body | reply |
|---|---|---|
| `GET /memory/health` | | `{enabled, ready, indexName, model, documentCount, cloudCopyLoaded, unpushedChanges, lastPushedAt}` |
| `POST /memory/upsert` | `{id, text, metadata:{concept, askedAt}}` or `{documents:[...]}` | `{enabled, ok, added, updated, documentCount}` |
| `POST /memory/query` | `{text}` or `{texts:[...]}`, `topK`=5, `alpha`=0.8 | `{enabled, ready, results:[{id, score, concept}], tookMs}` |
| `POST /memory/reset` | | `{enabled, ok}` |

Tuning: `pnpm test:moss-memory` indexes six sample memories into a throwaway local session (it is never pushed) and prints, for each model and alpha, the score of the right memory and of the best wrong one for the same test questions the on-device blend was tuned on. Moss's `score` is the semantic similarity rescaled to 0–1, and `alpha` changes the hybrid *ranking* (which candidates come back and in what order), not the score. The thresholds are `MemoryRecall.minimumMossScore` (prompt context) and `minimumMossScoreForSameIdeaNudge` (the unprompted nudge).

Results (Oct 24, 6 sample memories, 10 questions; every alpha gave the same ranking):

| | right memory ranked #1 | related found at threshold | unrelated rejected | query time |
|---|---|---|---|---|
| on-device blend (NLEmbedding + keywords) | — | 5/7 (missed closures, "volume zero") | 4/4 at 0.50 | <1 ms |
| Moss `moss-mediumlm` | 6/6 | 3/6 at 0.25 | 4/4 | ~2.8 ms |
| **Moss `moss-minilm` (used)** | **6/6** | **4/6 at 0.40** (det-3d 0.65, variance 0.84, backprop 0.59, closures 0.54) | **4/4** (max 0.38) | **~2.3 ms** |

Chosen: `moss-minilm`, `minimumMossScore` 0.40 for the tutor's context (the tutor makes the final call on whether it's really the same idea) and 0.55 for the unprompted "same idea" nudge. Misses (merge sort → big-O 0.07, "volume zero" → determinants 0.24) are paraphrases with no shared vocabulary.

## How sync works

Each beat's slot is its narration length plus a short pause. The scene prompt gets the cumulative end times as `T = [...]`, and the generated code calls `wait_until(self, T[i])` at the end of every beat. `wait_until` pads with `self.wait` and records the scene time it actually reached. If a beat's animations run long, the mux places that beat's narration where the beat really starts instead of drifting, and the last frame is held if the audio runs past the video.

## Layout

```
src/server.ts            HTTP + SSE
src/jobs.ts              in-memory jobs with an event log
src/llm.ts               OpenAI / Anthropic switch
src/pipeline/            script, voice, scene, render, mux, index (orchestration)
src/prompts/             script.md, scene.md, fix.md
manim/kit.py             16:9 style kit (written at Cal Hacks 13.0): hoot palette, helpers, `tex()` (real LaTeX when installed, else Text stand-ins), DecimalNumber→Text shims
manim/fonts/             JetBrains Mono (OFL), same files as the app
manim/KIT_API.md         kit docs pasted into the scene prompt
manim/templates/*.py     transform, derivation, process, compare (few-shot examples)
manim/fallback.py        beats as animated text; never fails
manim/runner.py          renders a scene with plain tracebacks
test/questions.json      5 fixed test questions
test/run.ts              pnpm test:questions [--parallel] [--only a,b]
test/paths.ts            exercise the fix and fallback paths on a finished job
test/moss-memory.ts      pnpm test:moss-memory: score table for tuning Moss recall
src/memory/moss.ts       Moss session for hoot's memory search
out/<jobId>/             per-job files: script, beats, audio, scene_N.py, error_N.txt, video.mp4
```

## Known limitations

- Jobs live in memory; finished mp4s are still served from `out/` after a restart.
- A bad tex string (unbalanced braces, Unicode inside, exotic macros) fails the render; the fix-retry usually repairs it, and the fallback scene uses no LaTeX. Without LaTeX installed, math is Unicode text and fractions are drawn as `a/b`.
- The scene model can still produce layouts with small overlaps; the prompt asks for a region plan and the kit has `fit`/`keep_in_frame`, but nothing checks the frames.
- Renders run in parallel with no queue; several jobs at once share the CPU.
- `POST /explain/:id/continue` from the plan is not built yet.
