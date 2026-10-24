// Tunes hoot's Moss memory recall: indexes sample memories into a local Moss
// session (never pushed, so no cloud index is created) and prints the score of
// the right memory and of the best wrong one for each test question, for a few
// models and alphas. Run: pnpm test:moss-memory
import { MossClient } from '@moss-js/moss';
import { env } from '../src/env.js';

if (!env.mossProjectId || !env.mossProjectKey) {
  console.log('MOSS_PROJECT_ID / MOSS_PROJECT_KEY are not set (worker/.dev.vars); nothing to test.');
  process.exit(0);
}

// Same shape the app indexes: "concept — question — answer summary".
const memories = [
  { id: 'determinants', text: 'determinants — what does the determinant of a matrix actually mean? — The determinant tells you how much a transformation scales area. If it is 2, every shape doubles in area; if it is 0, space gets squished flat onto a line.' },
  { id: 'variance', text: 'variance — what is variance in statistics? — Variance measures how spread out numbers are: the average of the squared distances from the mean. Bigger variance means the values are more scattered.' },
  { id: 'backpropagation', text: 'backpropagation — how does backprop work in a neural network? — Backprop uses the chain rule to send the error backwards from the output, so each weight learns how much it contributed to the loss.' },
  { id: 'big-o notation', text: 'big-o notation — what does big O notation mean? — Big O describes how an algorithm’s running time grows as the input gets bigger, ignoring constants, like O(n) for one pass or O(n²) for nested loops.' },
  { id: 'closures', text: 'closures — what is a closure in javascript? — A closure is a function that keeps access to the variables of the scope it was created in, even after that outer function has returned.' },
  { id: 'photosynthesis', text: 'photosynthesis — how do plants make food from sunlight? — Plants use light energy to turn water and carbon dioxide into glucose and oxygen inside their chloroplasts.' },
];

const cases: { query: string; expected: string | null }[] = [
  { query: 'what does det 0 mean for a 3d transformation', expected: 'determinants' },
  { query: 'how is standard deviation different from variance', expected: 'variance' },
  { query: 'how do gradients flow back through a layer', expected: 'backpropagation' },
  { query: 'why is merge sort n log n', expected: 'big-o notation' },
  { query: 'why does the inner function still see the variable after the outer one returns', expected: 'closures' },
  { query: 'why is the volume zero when the columns are linearly dependent', expected: 'determinants' },
  { query: 'how do i center a div in css', expected: null },
  { query: 'how does a for loop work', expected: null },
  { query: 'what is an eigenvector', expected: null },
  { query: 'who wrote the declaration of independence', expected: null },
];

const models = (process.env.MOSS_TEST_MODELS || 'moss-mediumlm,moss-minilm').split(',');
const alphas = (process.env.MOSS_TEST_ALPHAS || '1,0.8,0.6,0.4').split(',').map(Number);

const client = new MossClient(env.mossProjectId, env.mossProjectKey);
try {
  for (const model of models) {
    const session = await client.session(`hoot-memory-test-${model}`, model as 'moss-minilm');
    const t0 = performance.now();
    await session.addDocs(memories);
    console.log(`\n=== ${model}: indexed ${memories.length} memories locally in ${(performance.now() - t0).toFixed(0)} ms ===`);
    for (const alpha of alphas) {
      console.log(`\n-- alpha ${alpha} --   (right = score of the expected memory, rank; wrong = best other score)`);
      let minRight = 1, maxWrong = 0, rightAtTop = 0, related = 0;
      const times: number[] = [];
      for (const c of cases) {
        const q0 = performance.now();
        const result = await session.query(c.query, { topK: memories.length, alpha });
        times.push(performance.now() - q0);
        const docs = result.docs;
        const rightIndex = c.expected ? docs.findIndex((d) => d.id === c.expected) : -1;
        const right = rightIndex >= 0 ? docs[rightIndex].score : null;
        const wrong = Math.max(0, ...docs.filter((d) => d.id !== c.expected).map((d) => d.score));
        if (c.expected) {
          related++;
          if (rightIndex === 0) rightAtTop++;
          minRight = Math.min(minRight, right ?? 0);
        }
        maxWrong = Math.max(maxWrong, wrong);
        console.log(
          `${(c.expected ?? 'none').padEnd(16)} right=${right === null ? '  -  ' : right.toFixed(3)}${rightIndex >= 0 ? ` #${rightIndex + 1}` : '   '}  wrong=${wrong.toFixed(3)} (${docs.find((d) => d.id !== c.expected)?.id ?? '-'})  | ${c.query}`,
        );
      }
      const avg = times.reduce((a, b) => a + b, 0) / times.length;
      console.log(`=> top-1 ${rightAtTop}/${related}, lowest right ${minRight.toFixed(3)}, highest wrong ${maxWrong.toFixed(3)}, gap ${(minRight - maxWrong).toFixed(3)}, avg query ${avg.toFixed(1)} ms`);
    }
    await session.close();
  }
} finally {
  await client.close();
}
