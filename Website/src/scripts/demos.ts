// What makes each page on the home page work: its controls, worked out again as they move, in
// the visitor's own currency and units.

import {
  EYES,
  PEOPLE,
  ROPE,
  TIP,
  distance,
  fromSlider,
  horizonDistance,
  horizonFigure,
  length,
  money,
  period,
  seconds,
  type DemoID,
  type Units,
  type World,
} from "../lib/demos";

export interface Controller {
  /** The page has formed. */
  shown(): void;
  /** The page is going. */
  hidden(): void;
}

const still = matchMedia("(prefers-reduced-motion: reduce)");

function find<T extends Element = HTMLElement>(page: HTMLElement, selector: string): T {
  const found = page.querySelector<T>(selector);
  if (!found) throw new Error(`No ${selector} on the ${page.dataset.demo} page`);
  return found;
}

/** Fills a slider's track up to its knob's middle. */
function fill(slider: HTMLInputElement) {
  const min = Number(slider.min);
  const max = Number(slider.max);
  const part = (Number(slider.value) - min) / (max - min);
  slider.style.setProperty("--fill-to", `calc(${part} * (100% - 28px) + 14px)`);
}

export function controllers(stage: HTMLElement, units: Units): Record<DemoID, Controller> {
  const page = (id: DemoID) => find(stage, `[data-demo="${id}"]`);
  return {
    horizon: horizon(page("horizon"), units),
    bill: bill(page("bill"), units),
    groceries: groceries(page("groceries")),
    pendulum: pendulum(page("pendulum"), units),
  };
}

function horizon(page: HTMLElement, units: Units): Controller {
  const slider = find<HTMLInputElement>(page, '[data-in="height"]');
  const shown = { distance: find(page, '[data-out="distance"]'), height: find(page, '[data-out="height"]') };
  const svg = {
    gradient: find<SVGLinearGradientElement>(page, '[data-svg="gradient"]'),
    sight: find<SVGLineElement>(page, '[data-svg="sight"]'),
    stance: find<SVGLineElement>(page, '[data-svg="stance"]'),
    eye: find<SVGCircleElement>(page, '[data-svg="eye"]'),
    horizon: find<SVGCircleElement>(page, '[data-svg="horizon"]'),
  };
  const set = (element: Element, values: Record<string, number>) => {
    for (const [name, value] of Object.entries(values)) element.setAttribute(name, value.toFixed(2));
  };
  const update = () => {
    const height = fromSlider(Number(slider.value), EYES.low, EYES.high);
    shown.distance.textContent = distance(horizonDistance(height), units);
    shown.height.textContent = `${length(height, units)} up`;
    slider.setAttribute("aria-valuetext", length(height, units));
    fill(slider);
    const figure = horizonFigure(height);
    set(svg.gradient, { x1: figure.eye.x, y1: figure.eye.y, x2: figure.horizon.x, y2: figure.horizon.y });
    set(svg.sight, { x1: figure.eye.x, y1: figure.eye.y, x2: figure.beyond.x, y2: figure.beyond.y });
    set(svg.stance, { x1: figure.ground.x, y1: figure.ground.y, x2: figure.eye.x, y2: figure.eye.y });
    set(svg.eye, { cx: figure.eye.x, cy: figure.eye.y });
    set(svg.horizon, { cx: figure.horizon.x, cy: figure.horizon.y });
  };
  slider.addEventListener("input", update);
  update();
  return { shown() {}, hidden() {} };
}

function bill(page: HTMLElement, units: Units): Controller {
  const slider = find<HTMLInputElement>(page, '[data-in="tip"]');
  const [fewer, more] = page.querySelectorAll<HTMLButtonElement>("[data-step]");
  const out = (name: string) => find(page, `[data-out="${name}"]`);
  const shown = { each: out("each"), tip: out("tip"), people: out("people"), bill: out("bill"), tipAmount: out("tip-amount"), total: out("total") };
  let people = PEOPLE.start;
  const update = () => {
    const percent = Number(slider.value);
    const tip = (units.bill * percent) / 100;
    shown.each.textContent = money((units.bill + tip) / people, units);
    shown.tip.textContent = `${percent}%`;
    shown.people.textContent = `${people} people`;
    shown.bill.textContent = money(units.bill, units);
    shown.tipAmount.textContent = money(tip, units);
    shown.total.textContent = money(units.bill + tip, units);
    slider.setAttribute("aria-valuetext", `${percent}%`);
    fewer.disabled = people <= PEOPLE.low;
    more.disabled = people >= PEOPLE.high;
    fill(slider);
  };
  slider.addEventListener("input", update);
  for (const button of [fewer, more]) {
    button.addEventListener("click", () => {
      people = Math.min(PEOPLE.high, Math.max(PEOPLE.low, people + Number(button.dataset.step)));
      update();
    });
  }
  slider.value = String(TIP.start);
  update();
  return { shown() {}, hidden() {} };
}

function groceries(page: HTMLElement): Controller {
  const list = find<HTMLUListElement>(page, "[data-list]");
  const left = find(page, '[data-out="left"]');
  const form = find<HTMLFormElement>(page, "[data-add]");
  const input = find<HTMLInputElement>(form, "input");
  let touched = false;
  let timer = 0;
  const count = () => {
    const remaining = list.querySelectorAll('.check[aria-pressed="false"]').length;
    left.textContent = `${remaining} left`;
  };
  const toggle = (button: HTMLButtonElement) => button.setAttribute("aria-pressed", button.getAttribute("aria-pressed") === "true" ? "false" : "true");
  list.addEventListener("click", (event) => {
    const button = (event.target as Element).closest<HTMLButtonElement>(".check");
    if (!button) return;
    touched = true;
    toggle(button);
    count();
  });
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    const name = input.value.trim();
    if (!name || list.children.length >= 10) return;
    touched = true;
    const item = list.firstElementChild?.cloneNode(true) as HTMLLIElement;
    const button = item.querySelector<HTMLButtonElement>(".check");
    const label = item.querySelector(".name");
    if (!button || !label) return;
    button.setAttribute("aria-pressed", "false");
    label.textContent = name;
    list.append(item);
    input.value = "";
    count();
  });
  return {
    shown() {
      // Ticks one off by itself, to show it's a list you use (GroceriesDemo in WelcomeView.swift).
      if (touched || still.matches) return;
      timer = window.setTimeout(() => {
        const eggs = list.querySelectorAll<HTMLButtonElement>(".check")[1];
        if (touched || !eggs || eggs.getAttribute("aria-pressed") === "true") return;
        toggle(eggs);
        count();
      }, 2200);
    },
    hidden() {
      clearTimeout(timer);
    },
  };
}

function pendulum(page: HTMLElement, units: Units): Controller {
  const slider = find<HTMLInputElement>(page, '[data-in="rope"]');
  const worlds = find(page, "[data-worlds]");
  const arm = find(page, "[data-arm]");
  const shown = { period: find(page, '[data-out="period"]'), rope: find(page, '[data-out="rope"]') };
  /** How far it swings each way, in degrees. */
  const amplitude = 16;
  let world: World = "earth";
  let swing = period(ROPE.start, world);
  let phase = Math.PI / 2;
  let last = 0;
  let frame = 0;
  let onScreen = false;
  let showing = false;

  const update = () => {
    const position = Number(slider.value);
    const rope = fromSlider(position, ROPE.low, ROPE.high);
    swing = period(rope, world);
    shown.period.textContent = seconds(swing, units);
    shown.rope.textContent = length(rope, units);
    slider.setAttribute("aria-valuetext", length(rope, units));
    fill(slider);
    // The rope as drawn: 40 to 180 points, along the slider.
    const drawn = 40 + 140 * (position / 1000);
    arm.style.setProperty("--rope-scale", String(drawn / 180));
    arm.style.setProperty("--rope-length", `${drawn}px`);
    if (still.matches) arm.style.transform = `rotate(${amplitude * 0.6}deg)`;
  };

  // Its phase moves on by the time passed over the period, so a new length changes the pace
  // without a jump.
  const tick = (now: number) => {
    frame = 0;
    if (!showing || !onScreen || document.hidden || still.matches) return;
    if (last) phase += ((now - last) / 1000) * ((2 * Math.PI) / swing);
    last = now;
    arm.style.transform = `rotate(${(amplitude * Math.sin(phase)).toFixed(3)}deg)`;
    frame = requestAnimationFrame(tick);
  };
  const run = () => {
    if (frame || !showing || !onScreen) return;
    last = 0;
    frame = requestAnimationFrame(tick);
  };

  slider.addEventListener("input", update);
  const buttons = [...worlds.querySelectorAll<HTMLButtonElement>("[data-world]")];
  const select = (button: HTMLButtonElement) => {
    world = button.dataset.world as World;
    for (const each of buttons) {
      each.setAttribute("aria-checked", String(each === button));
      each.tabIndex = each === button ? 0 : -1;
    }
    worlds.style.setProperty("--at", String(buttons.indexOf(button)));
    update();
  };
  worlds.addEventListener("click", (event) => {
    const button = (event.target as Element).closest<HTMLButtonElement>("[data-world]");
    if (button) select(button);
  });
  worlds.addEventListener("keydown", (event) => {
    const button = (event.target as Element).closest<HTMLButtonElement>("[data-world]");
    if (!button) return;
    let step: number;
    switch (event.key) {
      case "ArrowRight":
      case "ArrowDown":
        step = 1;
        break;
      case "ArrowLeft":
      case "ArrowUp":
        step = -1;
        break;
      default:
        return;
    }
    event.preventDefault();
    const next = buttons[(buttons.indexOf(button) + step + buttons.length) % buttons.length];
    select(next);
    next.focus();
  });
  new IntersectionObserver(([entry]) => {
    onScreen = entry.isIntersecting;
    run();
  }).observe(arm.parentElement ?? page);
  document.addEventListener("visibilitychange", run);
  update();

  return {
    shown() {
      showing = true;
      run();
    },
    hidden() {
      showing = false;
    },
  };
}
