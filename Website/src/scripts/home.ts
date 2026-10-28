// The opening: what using Dream looks like, played once when the page opens. A request types
// itself into the composer in the middle of the screen; it's sent, and the composer rises; the
// Aura thinks, in the colors of the page to come; then the page forms, one block at a time, and
// works. After that, nothing moves unless the visitor asks for another page.
//
// With Reduce Motion, each page is simply there.

import { DEMOS, unitsFor, type DemoID } from "../lib/demos";
import type { Accent } from "../lib/palette";
import { startAura } from "./aura";
import { controllers } from "./demos";

const root = document.documentElement;
const still = matchMedia("(prefers-reduced-motion: reduce)");
const units = unitsFor(navigator.language);

function element<T extends HTMLElement = HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  if (!found) throw new Error(`No ${selector} on the page`);
  return found;
}

const composer = element("[data-composer]");
const hold = element("[data-hold]");
const typed = element("[data-typed]");
const said = element("[data-said]");
const sheet = element("[data-sheet]");
const stage = element("[data-stage]");
const others = element("[data-others]");
const pages = new Map(DEMOS.map((demo) => [demo.id, element(`[data-demo="${demo.id}"]`)]));
const working = controllers(stage, units);
const aura = startAura(element("[data-aura]"), root.dataset.accent as Accent, element("[data-hero]"));

const wait = (ms: number) => new Promise((done) => setTimeout(done, ms));

/** The page asked for last, which may still be forming. */
let asked: DemoID | null = null;
/** Each ask has a number; an older one stops when a newer one starts. */
let asking = 0;

async function ask(id: DemoID, opening = false) {
  const mine = ++asking;
  const current = () => mine === asking;
  const demo = DEMOS.find((each) => each.id === id);
  const page = pages.get(id);
  if (!demo || !page) return;
  const request = demo.request(units);
  asked = id;

  for (const button of others.querySelectorAll<HTMLButtonElement>("[data-ask]")) {
    button.setAttribute("aria-pressed", String(button.dataset.ask === id));
  }

  // The page that's there goes, and the sheet holds its size until the next one forms.
  if (sheet.hasAttribute("data-open")) sheet.style.height = `${sheet.offsetHeight}px`;
  for (const [other, element] of pages) {
    if (other === id || !element.hasAttribute("data-shown")) continue;
    element.setAttribute("data-leaving", "");
    element.removeAttribute("data-formed");
    working[other].hidden();
    setTimeout(() => {
      if (element.hasAttribute("data-leaving")) element.removeAttribute("data-shown");
    }, 260);
  }
  page.removeAttribute("data-formed");

  hold.textContent = request;
  said.textContent = `Asked: ${request}`;
  composer.removeAttribute("data-sent");
  composer.removeAttribute("data-ready");
  composer.setAttribute("data-live", "");

  if (still.matches) {
    typed.textContent = request;
    composer.setAttribute("data-ready", "");
    composer.setAttribute("data-sent", "");
    composer.setAttribute("data-docked", "");
    root.dataset.accent = demo.accent;
    aura.palette(demo.accent);
    page.removeAttribute("data-leaving");
    page.setAttribute("data-shown", "");
    page.setAttribute("data-formed", "");
    sheet.setAttribute("data-open", "");
    sheet.style.height = "";
    others.setAttribute("data-ready", "");
    working[id].shown();
    return;
  }

  // Typed, a letter at a time.
  typed.textContent = "";
  if (!opening) await wait(220);
  for (let count = 1; count <= request.length; count++) {
    if (!current()) return;
    typed.textContent = request.slice(0, count);
    await wait(opening ? 36 : 16);
  }
  composer.setAttribute("data-ready", "");
  await wait(opening ? 420 : 140);
  if (!current()) return;

  // Sent: the composer rises, and Dream thinks in the colors of the page to come.
  composer.setAttribute("data-sent", "");
  composer.setAttribute("data-docked", "");
  root.dataset.accent = demo.accent;
  aura.palette(demo.accent);
  aura.energy(1, 0.9);
  await wait(opening ? 1700 : 1000);
  if (!current()) return;

  // It writes, and the page forms on its sheet.
  aura.energy(0.5, 0.8);
  sheet.setAttribute("data-open", "");
  page.removeAttribute("data-leaving");
  page.setAttribute("data-shown", "");
  fit();
  // The blocks start from their unformed state before they form.
  void page.offsetWidth;
  page.setAttribute("data-formed", "");
  working[id].shown();
  await wait(900);
  if (!current()) return;
  aura.energy(0, 1.8);
  others.setAttribute("data-ready", "");
}

/** Eases the sheet from the size it held to the new page's, then lets it size itself again, so a
 * list can grow. */
function fit() {
  if (!sheet.style.height) return;
  const style = getComputedStyle(sheet);
  const target = stage.offsetHeight + parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
  if (Math.abs(target - sheet.offsetHeight) < 1) {
    sheet.style.height = "";
    return;
  }
  sheet.style.height = `${target}px`;
  setTimeout(() => {
    if (sheet.style.height === `${target}px`) sheet.style.height = "";
  }, 700);
}

others.addEventListener("click", (event) => {
  const button = (event.target as Element).closest<HTMLButtonElement>("[data-ask]");
  const id = button?.dataset.ask as DemoID | undefined;
  if (id && id !== asked) void ask(id);
});

// It starts once the typeface is in, so the request doesn't change face as it types.
void Promise.race([document.fonts.ready, wait(1500)])
  .then(() => wait(still.matches ? 0 : 500))
  .then(() => ask(DEMOS[0].id, true));
