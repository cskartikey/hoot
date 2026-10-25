## Inspiration

i watch a lot of lectures on youtube. 3blue1brown, random MIT stuff, whatever. and every single time there's this moment where the guy says "so obviously the determinant is zero here" and i'm like wait, what? i lost the thread two sentences ago. my options are pause, open a new tab, google it, read three stack exchange answers that don't match the slide, and lose the whole flow. or just keep watching and pretend.

the thing that actually works is having a friend next to you who already gets it. they point at the line on your screen, scribble on your notes, say "go back to the part where she defined it," and when you're hopeless they just grab the mouse and do it. i wanted that friend. so i made it twelve pixels tall and put it in the corner of my screen.

## What it does

hoot is a pixel owl that sleeps in the bottom right of your mac. you hold ⌃⌥ and talk. it hears you, sees all your screens, grabs the youtube transcript if a lecture is playing, pauses the video, and answers out loud. and then it does the stuff a chatbot can't:

- **it points.** a little index card frame lands on the term, the line of code, or the button you asked about. it can ring one symbol in an equation and draw an arrow to the thing it multiplies.
- **it draws on your notes.** a napkin sketch shows up next to what you're reading, stroke by stroke, timed to the sentence that mentions each part.
- **it rewinds.** say "go back to where he explained what a determinant is" and it finds the spot in the transcript, says the time, and jumps the video there.
- **it makes you a picture.** a quick animated sketch when the idea is about motion, or a 30 second narrated manim video with real typeset math when it's an equation building up.
- **it walks you through stuff.** "how do i share this doc" gets you steps with the frame sliding from button to button. say "just do it" and it takes the mouse: the cursor flies to each step and clicks, re-finds the next button on a fresh screenshot, and stops the second you touch the trackpad.
- **it doesn't let you off easy.** ask what happens next in a lecture and it makes you guess first. say "quiz me" and it asks you one applied question after the answer, and grades you on your next hold.
- **it remembers.** every answer gets filed under a concept. when you ask something related later it goes "this is the determinant thing from tuesday, just in 3d." stuff comes due on a spaced review ladder and the owl waves from the corner, asks you the question, listens, and grades you.

three mascots, light and dark mode, and you can pick the brain (Claude or OpenAI) and the voice (Cartesia or ElevenLabs) in settings.

## How I built it

solo, all of it written this weekend.

- the app is swift. swiftui on top of appkit. menu bar status item, one transparent overlay window per screen for the owl and the frames, a global ⌃⌥ key monitor, screencapturekit for screenshots of every display.
- ears: AssemblyAI v3 streaming, with auto end of turn while the key is held.
- brain: Claude through the Anthropic messages api, Sonnet 5.5 by default and Opus 5.5 if you want. one streamed request with the screenshots as image blocks. a tiny worker (cloudflare workers runtime, running locally) proxies it, and can translate the exact same request to OpenAI so i could build without a key.
- the trick that makes it all work: the reply is plain spoken text followed by tags. `[POINT:x,y,w,h:label]`, `[DRAW:arrow|circle|underline|label]`, a `[NAPKIN:...]` stroke language, `[SKETCH:brief]`, `[VIDEO:brief]`, inline `[STEP n/N POINT:...]` for walkthroughs, `[SEEK:mm:ss]`, `[PREDICT]`, `[CHECK:question]`, `[CONCEPT:words]`, `[REVIEW:grade]`. the app parses them as the stream comes in, so hoot starts talking after the first sentence and the frame, the marks, and the napkin land while it's still speaking.
- voice: Cartesia sonic-3.6, one clip per sentence, queued as the llm finishes each sentence. so speech starts before the answer is done. ElevenLabs eleven_v4 is a switch in settings. walkthrough steps and napkin strokes fire when each sentence's clip starts.
- youtube: applescript running javascript inside chrome, arc, brave, edge or safari to pause, resume and seek the player. the worker pulls the caption track and caches it.
- the studio turns `[VIDEO:]` briefs into actual videos. one llm call writes a beat script, Cartesia narrates each beat, another call writes a manim scene against a house kit (palette, helpers, real latex through mactex), it renders with a fix-retry and an animated text fallback, and ffmpeg muxes the narration and captions. about 45 seconds start to finish.
- memory: a json file on the mac, semantic recall through Moss (on-device embeddings as fallback), the spaced review ladder, and corner nudges that wait until hoot isn't mid answer.
- just do it: cgevent cursor moves and clicks, one locate call per step that re-finds the control on a fresh screenshot, hard stop on any mouse movement from you.
- design: the pixel mascots, colors and the overlay language came from a Claude Design handoff, exported to sprite json and drawn with nearest neighbor scaling so they stay crisp.

## Challenges I ran into

- resizing the menu panel synchronously crashed appkit with "more Update Constraints in Window passes." every resize is async now.
- swiftui's head truncation is broken on multi line text, so the answer bubble shows a sliding window of the last sentences instead.
- youtube's caption endpoints take 2 to 4 seconds and the fallback page scrape takes 13. the app gave up at 5, so the first question on any video got told "no transcript." fixed with caching in the worker, shared lookups, a second player client, longer waits for rewind questions, and never remembering a flaky miss as "this video has no captions."
- manim's text had no glyphs for subscript letters in the system font, so one explainer video rendered θ_new as "θ▯ew". the kit only uses glyphs the font actually has now and sends word subscripts to latex.
- the model kept drawing sketches in a tiny 50 by 110 corner of a 640 by 360 canvas. the app now measures the drawing and sends a tiny one back for a redraw.
- review nudges and the corner owl kept piling on top of the explainer panel while a sketch was rendering, because "panel is open" was only true once a picture was showing.
- posting clicks needs the accessibility permission specifically, and a rebuild can silently drop it. hoot checks and tells you instead of just pointing and acting like it clicked.

## Accomplishments that I'm proud of

the whole ladder works end to end. from "wait, what?" to the owl clicking through a share dialog by itself. the pointing frame lands on the right term on a retina screen from a pixel box the model picked. the studio writes, narrates, renders and repairs a manim video in under a minute, with real fractions. and it's one person and 36 hours.

## What I learned

tags inside spoken text beat structured tool calls when the output has to be heard while it streams. speaking sentence by sentence changes everything, a four second wait turns into a conversation. almost every demo failure was a timing race, not the model being dumb. and a tutor that makes you guess first is a different product from one that just answers.

## What's next

transcripts for any video, not just youtube: live system audio transcription so the same rewind works on a zoom lecture. walkthroughs that can type, with the same "only if you say so" rule. and sharing a saved explainer with your study group.

## For the sponsor judges

**Cartesia.** voice is the product, there's no text box. i use sonic-3.6 text to speech through the api, one clip per sentence queued while the answer streams so it starts talking within the first sentence, a picker with four voices, and a speed slider. the explainer studio narrates every beat with Cartesia too. known limitations: clips are fetched per sentence instead of streaming audio chunks, and very short sentences get merged before synthesis so the voice doesn't clip.

**Moss.** hoot's memory recall runs on Moss. every answered question gets indexed under its concept, and the next question is searched against it so the tutor can say "this is the determinant idea from tuesday, just in 3d." spaced review and the corner nudges sit on the same store.

**Anthropic.** the community is students learning from recorded lectures alone at night with nobody to ask. the problem is the three seconds after you lose the thread. the one thing done well: a question answered out loud with a finger on the screen. Claude does the part that matters, it reads the screen and the transcript, decides what to point at, and writes the tag grammar everything else hangs off. where it can go wrong: it can misread what's on screen, so the prompt tells it to say when it isn't sure, to point instead of describe, and to never make up screen content. a wrong box is something you can see and correct, not a silent mistake. "just do it" only clicks after you say so out loud, never types, and stops the moment you touch the mouse. memory stays on your mac and you can wipe it from the panel. the brain is model agnostic, and the demo video was recorded on the OpenAI fallback while a Claude key was pending.

**ElevenLabs.** a switch in settings for both answers and explainer narration, eleven_v4 with four library voices.
