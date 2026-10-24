// Writes Hoot/Resources/Pets/<name>.json (PetSprites schema) for each pet in pets.js.
//   node design/crisp/export-sprites.cjs
const fs = require("fs");
const path = require("path");
const pets = require("./pets.js");

const OUT = path.resolve(__dirname, "../../Hoot/Resources/Pets");
const NAMES = { owl: "hoot", lotl: "lotl", bit: "bit", owlhead: "hoot-head" };

// "#RRGGBB" → "#RRGGBBFF", "rgba(r,g,b,a)" → "#RRGGBBAA"
function toHex8(color) {
  if (color.startsWith("#")) return (color + "FF").toUpperCase();
  const [r, g, b, a] = color.match(/[\d.]+/g).map(Number);
  const hex = (n) => Math.round(n).toString(16).padStart(2, "0");
  return ("#" + hex(r) + hex(g) + hex(b) + hex(a * 255)).toUpperCase();
}

fs.mkdirSync(OUT, { recursive: true });
for (const [pet, name] of Object.entries(NAMES)) {
  const palette = Object.fromEntries(Object.entries(pets.PAL[pet]).map(([ch, c]) => [ch, toHex8(c)]));
  const animations = {};
  const stateNames = Object.keys(pet === "owlhead" ? pets.HEAD_STATES : pets.STATES);
  for (const state of stateNames) {
    animations[state] = pets.frames(pet, state).map(({ grid, ms }) => ({
      rows: grid.map((row) => row.map((ch) => ch || ".").join("")),
      ms,
    }));
  }
  const file = path.join(OUT, `${name}.json`);
  const size = animations.idle[0].rows.length;
  fs.writeFileSync(file, JSON.stringify({ size, palette, animations }));
  console.log(`wrote ${path.relative(process.cwd(), file)}`);
}
