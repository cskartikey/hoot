## Inspiration

You know this moment. You're watching a lecture at 1am, the professor says "and so the determinant is zero here," and you lost the thread two sentences ago. You have two options. Pause, open a new tab, search, read three answers that don't match the slide, and lose the flow. Or keep watching and quietly give up on that chapter.

The best way anyone learns is sitting next to a friend who already gets it. They lean over, point at the line on your screen, scribble in the margin of your notes, say "no, go back to the part where she defined it," and when you're hopeless they grab the mouse. I wanted that friend, shrunk to twelve pixels in the corner of my screen.

## What it does

hoot is a pixel-art owl that lives in your Mac's menu bar and dozes in the corner of your screen. Hold ⌃⌥ and talk. It hears you, sees every screen, reads the YouTube transcript if a lecture is playing, pauses the video, and answers out loud. Then it does the things a tutor does that a chatbot can't:

- **It points.** An index-card frame lands on the term, the line of code, or the button you asked about, on whichever monitor it's on. It can ring one symbol in an equation, draw an arrow to what it multiplies, underline the exact words.
- **It draws on your notes.** A napkin sketch appears beside what you're reading, stroke by stroke, each part drawn as the sentence that names it is spoken.
- **It rewinds.** "Go back to where he explained what a determinant is" finds the moment in the transcript, says the time out loud, and jumps the video there.
- **It makes you a picture.** An animated sketch in seconds when the idea is motion, or a narrated 30-second Manim explainer video with real typeset math when it's an equation building up.
- **It walks you through things,** and if you say "just do it," it takes the mouse: the cursor flies to each step and clicks, re-finding each control on a fresh screenshot, stopping the instant you touch the trackpad.
- **It doesn't let you off easy.** When you ask what happens next in a lecture, it asks for your guess first. "Quiz me" adds one applied question after an answer, graded on your next hold.
- **It remembers.** Every answer is stored under a concept. Related past confusions come back as a one-line callback in later answers. Concepts come due on a spaced-review ladder, and hoot nudges from the corner, asks the question, listens hands-free, and grades you.

Three mascots, light and dark mode, and a choice of brain (Claude or OpenAI) and voice (Cartesia or ElevenLabs) in settings.

## How I built it

Everything was written during the event, solo.

- **The app** is Swift, SwiftUI on AppKit: a menu-bar status item, a transparent overlay window per screen for the owl and its frames, a global ⌃⌥ key monitor, and ScreenCaptureKit screenshots of every display.
- **Ears:** AssemblyAI's v3 streaming API with automatic end-of-turn while the key is held.
- **Brain:** Claude through the Anthropic Messages API (Sonnet 5.5 by default, Opus 5.5 in settings). The whole reply is one streamed request with the screenshots as image blocks. A small worker (Cloudflare Workers runtime, run locally) proxies it and can translate the same request to OpenAI for development without a key.
- **A tag grammar instead of tool calls.** The tutor's reply is plain spoken text followed by tags: `[POINT:x,y,w,h:label]`, `[DRAW:arrow|circle|underline|label]`, `[NAPKIN:...]` stroke language, `[SKETCH:brief]`, `[VIDEO:brief]`, inline `[STEP n/N POINT:...]` for walkthroughs, `[SEEK:mm:ss]`, `[PREDICT]`, `[CHECK:question]`, `[CONCEPT:words]`, `[REVIEW:grade]`. The app parses them as the stream arrives, so hoot starts talking after the first sentence and the frame, marks, and napkin land while it speaks.
- **Voice:** Cartesia sonic-3.6, one clip per sentence, queued as the LLM finishes each sentence, so speech starts before the answer is done. ElevenLabs eleven_v4 is a switchable alternative. Walkthrough steps and napkin strokes are timed to the moment each sentence's clip starts.
- **YouTube:** AppleScript-driven JavaScript in Chrome, Arc, Brave, Edge or Safari pauses, resumes and seeks the player; the worker fetches the caption track and caches it.
- **The studio** turns `[VIDEO:]` briefs into explainer videos: an LLM writes a beat script, Cartesia narrates each beat, a second LLM call writes a Manim scene against a house kit (palette, helpers, real LaTeX through MacTeX), the render runs with a fix-retry and an animated-text fallback, and ffmpeg muxes narration and captions. About 45 seconds end to end.
- **Memory:** a JSON store on the Mac, semantic recall with Moss (on-device embeddings as fallback), a spaced-review ladder, and corner nudges gated so they never interrupt an answer.
- **Just do it:** CGEvent cursor flight and clicks, a locate call per step that re-finds the control on a fresh screenshot, and hard stops on any mouse movement by the learner.
- **Design:** the pixel mascots, tokens and overlay language came from a Claude Design handoff, exported to sprite JSON and rendered with nearest-neighbour scaling.

## Challenges I ran into

- Resizing the menu panel synchronously crashed AppKit with "more Update Constraints in Window passes"; every resize is now applied asynchronously.
- SwiftUI's head truncation is broken on multi-line text, so the answer bubble shows a sentence-window tail of what's being said instead.
- YouTube's caption endpoints take two to four seconds, and the watch-page fallback thirteen. The app gave up at five, so the first ask on any video was told there was no transcript. Fixed with in-memory caching in the worker, shared lookups, a second player client, longer waits for rewind questions, and never caching a transient miss as "no transcript."
- Manim's Text had no glyphs for subscript letters in the system font, so an explainer video rendered θ_new as "θ▯ew". The kit now uses only glyphs the font has and sends word subscripts to LaTeX.
- The model would sometimes draw a sketch in a 50×110 corner of a 640×360 canvas. The app now measures the drawing's extent and sends a tiny one back for a redraw.
- Review nudges and the corner owl piled onto the explainer panel while a sketch was rendering, because "panel open" was only true once a picture was showing.
- Posting clicks needs the Accessibility permission specifically, and a rebuild can silently drop it. hoot checks and says so instead of silently pointing.

## Accomplishments that I'm proud of

The whole ladder works end to end, from "wait, what?" to hoot clicking through a share dialog on its own. The pointing frame lands on the right term on a Retina screen from a model-chosen pixel box. The explainer studio writes, narrates, renders and repairs a Manim video in under a minute, with real typeset fractions. And it's one person's 36 hours.

## What I learned

A tag grammar inside spoken text beats structured tool calls when the output has to be heard while it streams. Speaking sentence by sentence changes the whole feel: a four-second wait becomes a conversation. Most demo failures were timing races, not model mistakes. And a tutor that asks for your guess first is a different product from one that answers.

## What's next

Transcripts for any video, not just YouTube: live system-audio transcription so the same rewind works for a Zoom lecture. Walkthroughs that can type, with the same consent rule. And sharing a concept's saved explainer with a study group.

## For the sponsor judges

**Cartesia.** Voice is the product: hoot has no text box. Features used: sonic-3.6 text-to-speech through the API, per-sentence clips queued as the answer streams so speech starts within the first sentence, a voice picker with four voices, and a speed control. The explainer studio narrates each beat with Cartesia too. Known limitations: clips are fetched per sentence rather than streamed as audio chunks, and very short sentences are merged before synthesis so the voice doesn't clip.

**Moss.** hoot's memory recall runs on Moss: every answered question is indexed under its concept, and the next question is searched against it so the tutor can say "this is the determinant idea from Tuesday, just in 3D." Spaced review and the corner nudges are built on the same store.

**Anthropic.** The community is students learning from recorded lectures alone, at night, with no one to ask. The problem is the three seconds after you lose the thread. The one thing done well is a question answered out loud with a finger on the screen. Claude does the thing that matters: it reads the screen and the transcript, decides what to point at, and writes the tag grammar every other feature hangs off. Where it can go wrong: it can misread what's on screen, so the prompt tells it to say when it isn't sure, to point rather than describe, and never to invent screen content; a mis-aimed box is visible and correctable rather than silent. "Just do it" clicks only after the learner says so out loud, never types, and stops the moment they touch the mouse. Memory stays on the Mac and can be wiped from the panel. The brain is model-agnostic; the demo video was recorded on the OpenAI fallback while a Claude key was pending.

**ElevenLabs.** Switchable in settings as the voice for answers and explainer narration, eleven_v4 with four library voices.
