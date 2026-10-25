## Inspiration

I watch a lot of technical lectures on YouTube and read technical books and blogs, and every single time I hit something that doesn't make sense. I rewind, rewatch, and I'm still like "...wait, what???" In those moments, I wish I had someone who could just explain it to me. And it sucks, because if it's hard enough, I usually end up dropping the whole thing.

What usually works is having someone explain it, or point out the one piece I missed. So I built that someone, that friend who does exactly that!

## What it does

hoot is a tiny pixel owl that sleeps in the corner of your Mac. When you hit something that doesn't make sense, you hold ⌃⌥ and just say it. "Wait, why does a zero determinant squish everything?" It hears you, looks at your screen, pulls the YouTube transcript if a lecture is playing, pauses the video, and explains it out loud. Like a friend would.

And then it does the things a friend does that a chatbot can't:

- **It points.** A little index card frame lands on the exact term, line of code, or button you asked about. If you ask "which one is the learning rate", it rings the η and draws an arrow to the thing it multiplies.
- **It draws on your notes.** A small napkin sketch shows up next to whatever you're reading, drawn stroke by stroke while it talks, so each part appears when it's mentioned.
- **It rewinds for you.** "Go back to where he explained what a determinant is." It finds the moment in the transcript, tells you the time, and jumps the video there.
- **It makes you a picture.** A quick animated sketch if the idea is about motion, or a 30 second narrated Manim video with real typeset math if it's an equation being built up.
- **It walks you through stuff.** "How do I share this doc?" gets you steps, with the frame sliding from button to button. And if you say "just do it", it takes the mouse. The cursor flies to each step and clicks, finds the next button on a fresh screenshot, and stops the second you touch the trackpad.
- **It doesn't let you off easy.** Ask what happens next in a lecture and it makes you guess first. Say "quiz me" and it asks one applied question after the answer, then grades you on your next hold.
- **It remembers.** Every answer gets filed under a concept. When you ask something related later, it says "this is the determinant thing from Tuesday, just in 3D." Concepts come due on a spaced review ladder, and the owl waves from the corner, asks you the question, listens, and grades you.

Three mascots, light and dark mode, and you can pick the brain (Claude or OpenAI) and the voice (Cartesia or ElevenLabs) in settings.

## How I built it

Solo. Every line was written this weekend.

- **The app** is Swift, SwiftUI on top of AppKit. A menu bar item, one transparent overlay window per screen for the owl and the frames, a global ⌃⌥ key monitor, and ScreenCaptureKit screenshots of every display.
- **Ears:** AssemblyAI v3 streaming, with automatic end of turn while the key is held.
- **Brain:** Claude through the Anthropic Messages API. Sonnet 5.5 by default, Opus 5.5 if you want it. One streamed request with the screenshots as image blocks. A tiny worker (Cloudflare Workers runtime, running locally) proxies it, and can translate the exact same request to OpenAI, which is how I built without a key.
- **The trick that makes everything work:** the reply is plain spoken text followed by tags. `[POINT:x,y,w,h:label]`, `[DRAW:arrow|circle|underline|label]`, a `[NAPKIN:...]` stroke language, `[SKETCH:brief]`, `[VIDEO:brief]`, inline `[STEP n/N POINT:...]` for walkthroughs, `[SEEK:mm:ss]`, `[PREDICT]`, `[CHECK:question]`, `[CONCEPT:words]`, `[REVIEW:grade]`. The app parses them as the stream comes in, so hoot starts talking after the first sentence, and the frame, the marks, and the napkin land while it's still speaking.
- **Voice:** Cartesia sonic-3.6, one clip per sentence, queued as the model finishes each sentence. Speech starts before the answer is done. ElevenLabs eleven_v4 is a switch in settings. Walkthrough steps and napkin strokes fire the moment each sentence's clip starts.
- **YouTube:** AppleScript running JavaScript inside Chrome, Arc, Brave, Edge or Safari to pause, resume and seek the player. The worker pulls the caption track and caches it.
- **The studio** turns `[VIDEO:]` briefs into actual videos. One model call writes a beat script, Cartesia narrates each beat, another call writes a Manim scene against a house kit (palette, helpers, real LaTeX through MacTeX), it renders with a fix-retry and an animated text fallback, and ffmpeg muxes the narration and captions. About 45 seconds start to finish.
- **Memory:** a JSON file on your Mac, semantic recall through Moss (on-device embeddings as the fallback), the spaced review ladder, and corner nudges that wait until hoot isn't mid-answer.
- **Just do it:** CGEvent cursor moves and clicks, one "locate" call per step that re-finds the control on a fresh screenshot, and a hard stop on any mouse movement from you.
- **Design:** the pixel mascots, colors and overlay language came from a Claude Design handoff, exported to sprite JSON and drawn with nearest neighbor scaling so they stay crisp.

## Challenges I ran into

- Resizing the menu panel synchronously crashed AppKit with "more Update Constraints in Window passes." Every resize is async now.
- SwiftUI's head truncation is broken on multi-line text, so the answer bubble shows a sliding window of the last sentences instead.
- YouTube's caption endpoints take 2 to 4 seconds, and the fallback page scrape takes 13. The app gave up at 5, so the first question on any video got told "no transcript." I fixed it with caching in the worker, shared lookups, a second player client, longer waits for rewind questions, and never remembering a flaky miss as "this video has no captions."
- Manim's Text had no glyphs for subscript letters in the system font, so one explainer video rendered θ_new as "θ▯ew". The kit only uses glyphs the font actually has now, and sends word subscripts to LaTeX.
- The model kept drawing sketches in a tiny 50 by 110 corner of a 640 by 360 canvas. The app measures the drawing now and sends a tiny one back for a redraw.
- Review nudges and the corner owl kept piling on top of the explainer panel while a sketch was rendering, because "panel is open" was only true once a picture was showing.
- Posting clicks needs the Accessibility permission specifically, and a rebuild can silently drop it. hoot checks and tells you, instead of pointing and pretending it clicked.

## Accomplishments that I'm proud of

The whole ladder works end to end, from "wait, what?" to the owl clicking through a share dialog by itself. The pointing frame lands on the right term on a Retina screen from a pixel box the model picked. The studio writes, narrates, renders and repairs a Manim video in under a minute, with real fractions in it. And it's one person and 36 hours.

## What I learned

Tags inside spoken text beat structured tool calls when the output has to be heard while it streams. Speaking sentence by sentence changes everything. A four second wait turns into a conversation. Almost every demo failure was a timing race, not the model being wrong. And a tutor that makes you guess first is a different product from one that just answers.

## What's next

Transcripts for any video, not just YouTube. Live system audio transcription, so the same rewind works on a Zoom lecture. Walkthroughs that can type, with the same "only if you say so" rule. And sharing a saved explainer with your study group.

## For the sponsor judges

**Cartesia.** Voice is the product. There's no text box. I use sonic-3.6 text to speech through the API, one clip per sentence queued while the answer streams so it starts talking within the first sentence, a picker with four voices, and a speed slider. The explainer studio narrates every beat with Cartesia too. Known limitations: clips are fetched per sentence instead of streaming audio chunks, and very short sentences get merged before synthesis so the voice doesn't clip.

**Moss.** hoot's memory recall runs on Moss. Every answered question gets indexed under its concept, and the next question is searched against it, which is how the tutor can say "this is the determinant idea from Tuesday, just in 3D." Spaced review and the corner nudges sit on the same store.

**Anthropic.** The community is students learning from recorded lectures alone at night, with nobody to ask. The problem is the three seconds after you lose the thread. The one thing done well: a question answered out loud with a finger on the screen. Claude does the part that matters. It reads the screen and the transcript, decides what to point at, and writes the tag grammar everything else hangs off. Where it can go wrong: it can misread what's on screen, so the prompt tells it to say when it isn't sure, to point instead of describe, and to never make up screen content. A wrong box is something you can see and correct, not a silent mistake. "Just do it" only clicks after you say so out loud, never types, and stops the moment you touch the mouse. Memory stays on your Mac and you can wipe it from the panel. The brain is model agnostic, and the demo video was recorded on the OpenAI fallback while a Claude key was pending.

**ElevenLabs.** A switch in settings for both answers and explainer narration, eleven_v4 with four library voices.
