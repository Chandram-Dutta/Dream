# Harness bench, 2026-10-27/28

The generation harness measured before and after fixing it, on seven fixed requests, through a
local server (`wrangler dev`, port 8791) with real models. Raw logs and the scripts are in the
session scratchpad (`harness/runs/<label>/<model>/r<n>.txt`); nothing here holds a key.

Requests: r1 split a 2400 rupee dinner bill four ways with a tip · r2 how do vaccines train the
immune system · r3 a packing list for a 3 day beach trip · r4 who won the 2026 FIFA World Cup
final, and how did the match go · r5 50 लाख के होम लोन की EMI कितनी होगी, 20 साल के लिए ·
r6 explain the quadratic formula and let me change a, b and c · r7 how has India's population
grown since 1950. Thinking "low" (everyone's level).

## What goes to the model per page

- Each call that writes the screen: instructions 18.8k characters (~4.7k tokens), the screen's JSON
  schema 19.0k (~4.8k tokens), five tools 3.6k (~0.9k). Grok counts about 11,950 tokens before
  the request itself (~150 tokens: request, language, region, date).
- The gap check: about 1,950 tokens.
- Grok makes 2 to 6 calls a page (the gap check, then 1 to 5 rounds of tools and writing), about
  35k input tokens and 2.5k output (half of it thinking). Input was about 80% of Grok's cost.

## Results

Pages made / 7, median seconds, dollars per page, share of input read from the prompt cache.
Before = the code at 18b83bb. "Before 1" ran 21 pages at once and its bench binary waited on a
Keychain prompt, adding ~20 s a page; the later runs don't.

| Run | Grok 4.7 | DeepSeek V4.1 Flash | Gemma 4 (Sarvam) |
| --- | --- | --- | --- |
| before 1 | 7, 44.6 s*, $0.069, 40% | 6, 42.9 s*, $0.004 | 4, 23 s |
| before 2 | 7, 33.0 s, $0.073, 34% | 4 (3 × 502), 20 s, $0.001 | 0 (all "busy") |
| before 3 (cheap, one at a time) | | 6, 24.6 s, $0.002 | 1 (busy, one 80 s runaway) |
| before 4 (Gemma, paced 40 s) | | | 2, five ran 80 s to the 32k cap |
| after 3 | 7, 25.5 s, $0.053, 61% | 7, 55.8 s, $0.008 | 0 (busy mid-round: fixed after) |
| after 4 | 7, 34.9 s, $0.053, 62% | 7, 60.7 s, $0.014 | 6 (one a lone slider: fixed after) |
| final | 7, 20.0 s, $0.051, 81% | 6 (+1 at 255 s), 54.5 s, $0.016 | 3 (paced 60 s) |

Quality, by hand:
- Before, DeepSeek and Gemma never called a tool (0 calls in 49 pages). The World Cup page was
  hollow or wrong every time ("I'll look this up.", "Searching for the result.", "the final
  hasn't been played"). DeepSeek's Hindi EMI page came out empty 2 of 3 times.
- After, DeepSeek uses tools on 6–7 of 7 pages; its World Cup page is right and cited (Spain 1–0
  Argentina, a.e.t., Torres 106'), its Hindi EMI page cites October 2026 rates, its quadratic has
  the parabola chart. It's slower: about a minute a page, as it thinks twice on the last round.
- Grok's pages are as before; it no longer looks things up for a packing list. Its schema now
  arrives in the declared order (title first), and its prompt cache holds from round to round.
- Gemma searches and reads now, but pads its answers with blanks in most pages under the schema;
  the padding is cut in seconds instead of running 80 s, but many pages still fail.

Model spend for all of this: about $3.93 (Grok's from xAI's own cost; Sarvam's at the guessed
prices in models.ts).

## Still open

- DeepSeek's packing list ran to the 32k cap twice even with the length guard, probably thinking
  again after its answer began; ChatCompletions.Padding now stops that. Run once more on the
  packing list (2026-10-28), the page came out whole in 45 s with no thinking after the answer
  began, so the guard neither fired nor got in the way; the runaway itself didn't recur.
- Gemma's padding under Sarvam's schema enforcement; Sarvam's rate limit on this key.
- DeepSeek sometimes looks things up for pages that need nothing (a bill split).
