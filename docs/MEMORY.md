# hoot memory — plan

Goal: hoot remembers what *you* got stuck on, brings it back when it's relevant, and helps it stick. Everything stays on this Mac.

Scope (agreed):
1. Memory store + capture
2. Semantic recall (embeddings)
3. Callbacks in answers
4. "hoot remembers" chips
5. Replay a past question (video / answer)
6. Forget everything
7. Spaced review
8. Corner nudges (review due · video ready · "same idea as before")

Out of scope: cloud sync, editing single memories, multiple users, LLM-written flashcard decks, analytics.

---

## 1. Data model

One JSON file: `~/Library/Application Support/hoot/memory.json` (written atomically; small enough to load fully).

```
MemoryEntry
  id                UUID
  askedAt           Date
  question          String          // what they said
  concept           String          // 1–3 words, lowercase, from [CONCEPT:]
  answerSummary     String          // first ~2 sentences of the spoken answer
  sourceTitle       String?         // YouTube title or app name
  youTubeVideoId    String?         // + timestamp, so "open at 6:52" is possible
  youTubeTimeSeconds Double?
  explainerVideoURL String?         // studio mp4, filled in when the video finishes
  embedding         [Float]         // see §2

ConceptReview                       // one per concept (not per question)
  concept           String
  timesAsked        Int
  lastAskedAt       Date
  reviewStage       Int             // 0,1,2,3… → interval ladder
  nextReviewAt      Date?
  lastReviewResult  .remembered | .shaky | .forgot | nil
```

`RecentQuestionsStore` is replaced by `MemoryStore` (the panel's "recent" list reads from it).

## 2. Capture

- The tutor appends a hidden tag after the others: `[CONCEPT:determinants]`. Same pattern as `[VIDEO:]` / `[POINT:]` — no extra LLM call. Parsed in `HootResponseTags`, stripped from speech and bubble.
- After an answer finishes, `HootController` writes a `MemoryEntry` and bumps the concept's `ConceptReview` (first time → schedule review stage 0).
- `ExplainerPanelManager` reports the finished video URL → `MemoryStore.attachExplainerVideo(url, toEntry:)`.
- Skip saving for chit-chat: no concept tag, or `[CONCEPT:none]`.

## 3. Embeddings + semantic recall

- **Embedder:** Apple's on-device `NLEmbedding.sentenceEmbedding(for: .english)` (NaturalLanguage). Private, free, no network, ~ms per call. Behind a small `TextEmbedder` protocol so a worker `/embed` route (OpenAI `text-embedding-3-small`) can be swapped in if on-device quality is too weak for technical text.
- **Indexed text per entry:** `concept + " — " + question + " — " + answerSummary`.
- **Query text:** the new question + the YouTube title + the last ~3 transcript lines (if a video was paused).
- **Search:** brute-force cosine over all entries (hundreds at most). Return top 3 with similarity ≥ threshold (start at 0.70, tune on real data), plus any exact concept-word match.
- **Prompt block** (added to the user prompt, not the system prompt):
  ```
  things this learner got stuck on before (most related first):
  - determinants (asked 3×, last tuesday): "the determinant is how much a transformation stretches area…"
  - linear transformations (once, today): "…"
  ```
  Only included when something passes the threshold.

## 4. Callbacks (prompt rule)

Add to `HootTutorPrompt`:
> if one of the earlier things they got stuck on is genuinely the same idea, connect it in one short clause ("this is the determinant idea from tuesday, just in 3D"). never force it, never list past topics, at most one callback per answer.

## 5. "hoot remembers" chips (home panel)

- Top 4 concepts by `timesAsked`, recent first on ties: `determinants ×3` `closures ×2` `variance` `backprop`.
- Top chip uses accent2 styling (per design); others neutral.
- Click a chip → the recent list filters to that concept (one tap again clears). Empty state: section hidden.

## 6. Replay a past question

- Recent rows become buttons:
  - has `explainerVideoURL` → reopen the explainer panel straight into playback (new `ExplainerPanelManager.playSavedVideo(url:title:)`; studio still serves old jobs from `studio/out/`).
  - no video → open a small answer card (the saved summary + source) in the response-bubble style, near the panel.
- If the video file is gone (studio reset), fall back to the answer card.

## 7. Forget everything

Settings → "memory" section: `hoot remembers N things` + a destructive "forget everything" button with a confirm step. Deletes `memory.json`, clears conversation history and recent list. Also a "nudges" on/off toggle (§8).

## 8. Spaced review

- **Ladder per concept:** stage 0 → +1 day, 1 → +3 days, 2 → +7 days, 3 → +21 days, then done. Asking about the concept again resets to stage 0 (you were confused again).
- **Demo mode** (hidden setting / launch env `HOOT_REVIEW_DEMO=1`): ladder in minutes (2, 5, 10, 20) so a review shows up during judging.
- **When due:** a review nudge (see §9): *"quick check: what does a zero determinant mean?"* `[answer]` `[later]`.
- **Question:** generated lazily when the review comes due (one small LLM call through `/chat`, text only): from the concept + saved summaries, ask for one short, spoken-friendly recall question. Cached on the `ConceptReview`.
- **Answering:** `[answer]` (or just holding ⌃⌥ while the nudge is up) starts a review turn: the learner answers out loud, the tutor runs in **review mode** (extra prompt: "grade the answer: remembered / shaky / forgot; reply in one or two encouraging sentences; if they forgot, re-explain in one line") and appends `[REVIEW:remembered|shaky|forgot]`.
  - remembered → next stage · shaky → same stage, half the interval · forgot → stage 0, and offer the saved video if there is one.

## 9. Corner nudges

Design: `wait what Cursor.dc.html` → "corner nudges" (220pt bubble beside the corner hoot, `hello` pose, primary + secondary pill buttons).

- **Triggers (three, opt-in via the "nudges" toggle, default on):**
  1. **Review due** (§8).
  2. **Video ready while away:** an explainer finished while the panel was closed or you were in another app → "your animation's ready: *why det = 0 squishes space*" `[▶ play]` `[later]`.
  3. **Same idea as before:** while a YouTube video plays, every ~60s embed the last ~45s of transcript (we already fetch transcripts); if it matches a past memory above a high threshold (≥0.80) → "psst, this is the same idea as **determinants** from tuesday." `[show me]` (opens that memory's video/answer) `[got it]`. Once per concept per day.
- **Etiquette rules (from the design):** at most one nudge per 10 min; never while the user is typing (key events in the last 5s), in fullscreen, or while hoot is answering; auto-fades after 8s; three ignored in a row → nudges pause until tomorrow.
- **UI:** a new small clickable window anchored to the corner hoot (like the corner click target), so buttons work while the overlay stays click-through.

---

## Build order and estimates

| # | Piece | Files | Est. |
|---|---|---|---|
| A | `MemoryStore` (entries, concept reviews, JSON persistence, forget) + `[CONCEPT:]` capture + video URL attach | new `Memory/MemoryStore.swift`, `HootResponseTags`, `HootController`, `ExplainerPanelManager`, `HootTutorPrompt` | 1.5h |
| B | Embeddings + recall + callback prompt | new `Memory/TextEmbedder.swift`, `Memory/MemoryRecall.swift`, `HootController`, `HootTutorPrompt` | 1h |
| C | Panel: chips + filter, replay rows, answer card, settings memory section | `UI/MenuPanelHomeView`, `UI/MenuPanelSettingsView`, `ExplainerPanelManager` | 1.5h |
| D | Nudge system: corner nudge window + bubble UI, rate limiting, video-ready trigger | new `UI/CornerNudge*.swift`, `Memory/NudgeScheduler.swift`, app delegate wiring | 1.5h |
| E | Spaced review: ladder, demo mode, lazy question, review turn + grading tag | `Memory/SpacedReview.swift`, `HootController`, `HootTutorPrompt`, `HootResponseTags` | 1.5h |
| F | "Same idea" nudge (transcript polling + match) | `Memory/RelatedContentWatcher.swift`, `YouTubeContextProvider` | 1h |

**Total ≈ 8h of work; with parallel agents ≈ 3–4h wall clock.** A must land first (everything reads the store); then B, C, D in parallel; then E and F (they need D's nudge UI).

**Cut line if time runs short:** keep A–D; E in demo mode only; drop F.

## Demo script additions
1. Ask about determinants (video made) → later ask about a 3D transformation → hoot: *"same idea as the determinant thing earlier, just in 3D."*
2. Open the panel → chips show `determinants ×2` → click the recent row → the old video replays.
3. With demo mode on, a couple of minutes later the corner hoot waves: *"quick check: what does a zero determinant mean?"* → answer out loud → "nailed it" → stage advances.

## Risks
- On-device embeddings may cluster technical phrases poorly → threshold tuning; swap to `/embed` if needed (swap is one protocol conformance).
- Nudges can feel naggy → strict rate limits, default-on only in demo mode if needed.
- Review grading by voice depends on transcription quality → grade generously ("shaky" rather than "forgot" when unsure).
