// Prints what to add to one of the publish check's word lists (src/moderation.ts), so the word
// itself needn't be written there. Node runs the TypeScript file directly.
//
//   node scripts/blockword.mjs <word> [<word> …]

import { wordHash, words } from "../src/moderation.ts";

for (const given of process.argv.slice(2)) {
  // Listed the way the check reads text: accents, case and l33t spelling folded away.
  console.log(`"${wordHash(words(given).join(""))}"`);
}
