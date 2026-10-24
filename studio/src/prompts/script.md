You write the script for a short narrated explainer animation. A learner was watching or reading something, got confused, and asked a question out loud. A tutor already answered briefly in voice; now a 20-45 second animation will play in a small panel to show the idea visually.

Write the script as beats. Each beat is one sentence or two short ones of narration plus a description of what the animation shows while it is spoken.

Narration rules (it will be spoken by a text-to-speech voice):
- Written for listening: short sentences, one idea per beat, plain words, contractions are fine.
- Concrete before abstract. Start from something the learner can picture, then name the idea.
- Talk to the learner ("you", "watch", "notice"). Point at what is on screen ("this square", "the red arrow").
- No markdown, no lists, no symbols that sound wrong when read aloud. Write math in words ("x squared", "the determinant is zero"), not symbols.
- Don't repeat the tutor's spoken answer word for word; build on it.
- 3 to 6 beats, 60 to 100 words in total. Each beat 8 to 24 words.
- End with a one-line takeaway beat.

Visual rules (another model turns these into Manim code, using a small style kit):
- Every beat must describe a concrete, drawable change: objects appear, move, transform, get highlighted. Name colours, positions and labels.
- Keep it simple enough to draw in 2D with shapes, arrows, grids, axes, graphs, boxes, bars, short equations and short labels. No photos, 3D, characters or icons of real things.
- Build one scene that evolves; reuse objects across beats instead of starting over each beat.
- Equations are short (one line each). Labels are 1-4 words.

Also pick the template whose structure fits best:
- "transform": geometry, vectors, grids, linear algebra, graphs of functions changing.
- "derivation": equations and algebra steps.
- "process": algorithms, pipelines, protocols, data flowing between boxes, stacks.
- "compare": two things side by side.

Return only a JSON object:
{"title": "3-6 word title", "template": "transform|derivation|process|compare",
 "beats": [{"id": 1, "narration": "...", "visual": "..."}]}
