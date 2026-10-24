# hoot × learnharness — plan

What to borrow from [learnharness](https://github.com/amosblomqvist/learnharness) (Amos Blomqvist's "agent harness for learning difficult things"), and how to grow hoot into a buddy that can also *show you how to do things*. Written Sat Oct 24 afternoon, against the tree at `8e9c54c` (memory landed: store, Moss recall, review turns, corner nudges).

learnharness is AGPL. We borrow ideas only, never code (which the event rules require anyway).

---

## 1. What learnharness is, in one paragraph

A desktop app for long, deliberate lessons. A **prober** agent quizzes you until it knows exactly where your understanding ends on every strand the goal depends on. A **teacher** agent then plans the smallest dependency tree from what you hold to what you want, and walks it **one reasoning step at a time**: a *prediction* before each step, the explanation, then a graded *check*. Separate **practice** sessions pose problems that force recall from a cold state. Everything learned is extracted into a persistent **knowledge graph** of propositions. Its system prompts (`src/agent/prompts/`) are the distilled form of a written theory (`docs/teaching-methodology.md`).

hoot is the opposite shape: a five-second interrupt while a lecture plays. So the session structure (probe → plan → teach, hour-long) does **not** transfer. The pedagogy doctrine does, and so does the idea that understanding should carry across sessions.

## 2. What hoot already covers (don't rebuild)

| learnharness | hoot today | Where |
|---|---|---|
| Knowledge graph of propositions, carried across sessions | Memory store: one entry per answered question, `[CONCEPT:]` tags, concept reviews | `Memory/MemoryCore.swift`, `docs/MEMORY.md` |
| "Graph context" fed into lessons | Semantic recall (Moss, on-device blend as fallback) → "things this learner got stuck on before" block + callback rule | `Memory/MemoryRecall.swift`, `Memory/MossMemorySearch.swift`, `HootTutorPrompt` "callbacks" |
| Practice sessions (recall from a cold state) | Spaced review: ladder per concept, lazily written quick-check question, review turn graded `[REVIEW:remembered|shaky|forgot]` | `Memory/SpacedReviewScheduler.swift`, `HootController.activeReviewTurn`, `HootTutorPrompt.reviewModePromptBlock` |
| Think-out-loud thinking fields (typed or dictated) | The whole input is spoken; the live transcript *is* the thinking field | `Input/` |
| Visual / demo sub-agents | Studio explainer videos (`[VIDEO:]`) | `studio/`, `ExplainerPanelManager` |
| Background research agent | not built, and not planned (see §6) | — |

## 3. Borrow: the teaching doctrine (prompt-only, ~1h total)

All four live in `HootTutorPrompt.tutorSystemPrompt`, under "how to tutor". Each gets one example reply so the model copies the register, not the rule.

1. **Discovered, not decreed** (learnharness Principle ii, "how could I have discovered this?"). Before the fact, say in one clause what problem forces it. "you need some number that says how much a matrix stretches area, so…" Not "the determinant is defined as…". Target: 3Blue1Brown.
2. **Start from one unconditional truth** (Principle i). Lead with the one thing they can accept at face value with no caveats, then build on it. Never start with the nuanced version.
3. **Name the wrong model.** When the question itself reveals a misconception ("so the gradient is the slope of the loss *over time*?"), say so in one plain clause before answering, instead of answering around it. learnharness: "a wrong answer is named plainly, never softened into half-approval."
4. **Voice: delete the defaults.** No "great question", no performed excitement, no "simply" (already banned), no reflex hedging. Warmth is the craftsmanship of the answer, not the wording. hoot keeps "a little playful"; it loses the praise.

Plus one cheap mechanic:

5. **Predict first** (learnharness's `type: "predict"`). When the video is paused and the question is about what comes next or why something *will* happen, hoot asks for a one-line guess and stops; the next hold is the guess, and the answer opens by resolving it ("you said it would shrink, and it does, but for a different reason…"). Uses the same "next hold answers hoot" turn as §4, so build them together.

## 4. Borrow: the applied check (~1.5h)

learnharness ends every step with a check. hoot gets one check per answer, **off by default**.

- **Trigger:** the learner says "quiz me" / "check me" in the question, or the settings toggle `quick checks after answers` is on.
- **Shape (from learnharness's question principles):** one short question that *applies* the idea to a new case, answerable from what hoot just said, never a recitation of hoot's words. Under fifteen words, spoken-friendly, ends with "?". Tag: `[CHECK:question]` right before `[CONCEPT:]`.
- **Answering:** the next ⌃⌥ hold answers it. Implementation reuses the review turn end to end: set `activeReviewTurn` with the check's concept and question, append `reviewModePromptBlock`, parse `[REVIEW:…]`, feed `MemoryStore.recordReviewResult`. The only new state is `pendingCheck: (concept, question)?` in `HootController`, consumed by the next `handlePushToTalkPressed`, dropped if the next question is about something else (the tutor says so with `[REVIEW:none]`).
- **Confidence read (from learnharness §confidence):** the review block already grades; add two lines: wrong *and* confident → correct plainly, name the crack; right but hesitant → one reinforcing sentence, no celebration.
- **Memory tie-in:** a check result lands on the concept's review ladder exactly like a spaced review, so a concept the learner nails right after learning it climbs a stage without waiting a day. Coordinate with the memory owner: `recordReviewResult` is the sink, nothing else changes.

## 5. Expand: "show me how to do it" (walkthrough mode, ~3–4h, then ~2h)

Today the controller takes only the **last** `[POINT:]` tag, so hoot can explain but can't guide. The ask: "how do I share this doc?" → hoot points at the share button while saying "click share", then at the permissions menu while saying "then switch this to anyone with the link".

### 5a. Multi-step pointing

- **Tag:** `[STEP:x,y,w,h:label]` written **inline**, right after the sentence it belongs to. Everything else stays at the end in the current order (spoken text → `[VIDEO:]` → `[CONCEPT:]` → `[POINT:]`). Prompt rule: use STEP only when the learner asks *how to do* something on screen; two to five steps; each step is one sentence that starts with the action verb.
- **Speech:** `HootResponseTags.speakableText` currently cuts at the first `[`. Change: strip inline STEP tags, cut at the first non-STEP tag. `enqueueCompletedSentences` records, per enqueued sentence, the STEP frame attached to it (if any).
- **Timing:** `CartesiaTTSClient` already knows when each sentence's clip starts (`play(audioData:revealing:)`). Add `onSentenceStarted(index)`; the controller publishes `detectedElementScreenLocation`/box/label for that sentence's frame; the coordinator's existing `handleDetectedElementLocationIfChanged` flies to it. The index-card frame redraws per step, the head hops between them.
- **Bubble:** the subtitle window already shows the sentence being spoken, so the text and the frame agree by construction. The bubble's frame-avoidance (`centerForBubbleNearHead`) keeps it off each step's box.
- **Memory:** walkthroughs are tagged `[CONCEPT:none]` unless a real idea was explained; procedures aren't review material.
- **Risk:** sentence splitting (`minimumSentenceLength = 24`) joins very short sentences; a step sentence like "click share." would be merged with the next. Fix: a sentence that carries a STEP tag is never merged.

### 5b. Watch and confirm (only if 5a lands with time to spare)

After the last step, wait ~4s, take one more screenshot, and ask the model with before + after images whether the step was done (one text-only answer plus an optional `[POINT:]`). hoot says "that's it" or points at what's still missing. Cap at one retry, never loop.

## 6. Deliberately not building

Probe sessions, the plan tree / DAG window, the knowledge-graph canvas, separate practice sessions, the background research agent, the demo builder, confidence sliders, thinking fields. All assume a seated hour; hoot's bet is the interrupt. If judges ask "why not a full tutor", the answer is: hoot is the tutor that shows up *where you already are*; memory is how it adds up.

## 7. Build order and estimates

Status (Sat Oct 24, evening): **1, 2 and 3 are built** (prompt doctrine; `[PREDICT]` guess-first; `[CHECK:question]` quick checks with the `quick checks` toggle, graded through `[REVIEW:]` into the review ladder). The "⌃⌥ follow up" pill reads "your guess" / "answer" while a question is open and the linger lasts 8s. 4 and 5 (walkthrough + watch-and-confirm) are built from the Claude Design spec (`docs/design/WALKTHROUGH.md`), plus three picture media that weren't in this plan: annotation marks over the pointed thing (`[DRAW:]`), instant SVG sketches in the panel (`[SKETCH:]`) and napkin sketches drawn on the screen in the same reply (`[NAPKIN:]`). Live behaviour is untested as of Sat evening.

| # | Piece | Files | Est. | Needs |
|---|---|---|---|---|
| 1 | Doctrine rules + examples | `HootTutorPrompt` | 45m | — |
| 2 | Predict-first | `HootTutorPrompt`, `HootController` (pending turn) | 20m | shares state with 3 |
| 3 | Applied check | `HootTutorPrompt`, `HootResponseTags` (`[CHECK:]`), `HootController` (`pendingCheck`), settings toggle in `MenuPanelSettingsView` | 1.5h | memory's review turn (landed) |
| 4 | Walkthrough mode | `HootTutorPrompt`, `HootResponseTags`, `HootController` (sentence↔step map), `CartesiaTTSClient` (`onSentenceStarted`), `PetOverlayCoordinator` | 3–4h | — |
| 5 | Watch and confirm | `HootController`, `ScreenCapturer` | 2h | 4 |

Deadline Sun Oct 25, 9:00am. 1–3 are one evening and change every demo answer. 4 is the headline if it works; start it only after 3 is committed. **Cut line:** if 4 is still shaky by midnight, cut it and polish the demo around memory + checks.

## 8. Demo script additions

1. Ask about determinants → hoot leads with the problem that forces the idea, no "great question". (§3)
2. Say "quiz me on that" → hoot asks one applied question; answer out loud → graded, the `determinants` chip climbs a stage. (§4)
3. On a Google Doc: "how do i share this with my study group?" → hoot points at share, then the access menu, then copy link, in step with its voice. (§5a)

## 9. Risks

- **Prompt drift.** Adding four rules to an already long prompt can make answers longer; keep the "two to five sentences" rule above them and re-test the three example questions after each edit.
- **Checks feel like homework.** That's why it's off by default and spoken as a quick "want to try one?". If it still grates in testing, drop the toggle and keep only "quiz me".
- **Walkthrough coordinates.** One wrong box in a three-step walkthrough is worse than a wrong single point. Keep steps to ≤5, box whole controls, and let the final `[POINT:]` be the fallback when the model can't place a step.
