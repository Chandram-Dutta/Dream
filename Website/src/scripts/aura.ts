// The Aura (Dream/UI/Aura.swift), full screen, drawn with WebGL: soft lights in three neighbouring
// hues of the page's color, wandering behind everything in the first screen. At rest they drift;
// while Dream thinks they speed up, swirl and brighten; while it writes they ease back. A light
// follows the visitor's pointer or finger.
//
// Speeds change by moving the field's own clock faster, never by changing a frequency, so
// nothing jumps. The field is soft, so it's drawn at a fraction of the screen's resolution and
// scaled up, which costs next to nothing. It stops when it's off screen or the tab is hidden,
// and with Reduce Motion it's drawn once and holds still.

import { COMPANION, SYSTEM, THIRD, type Accent } from "../lib/palette";

type RGB = [number, number, number];

export interface Aura {
  /** 0 at rest, about 0.5 while writing, 1 while thinking; it eases there. */
  energy(target: number, seconds?: number): void;
  /** Moves to a page's colors over a second or so. */
  palette(accent: Accent): void;
}

const VERTEX = `
attribute vec2 position;
varying vec2 uv;
void main() {
  uv = vec2(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);
  gl_Position = vec4(position, 0.0, 1.0);
}`;

const FRAGMENT = `
precision highp float;
varying vec2 uv;
uniform float time;
uniform float energy;
uniform float strength;
uniform vec2 shape;
uniform vec3 pointer;
uniform vec3 hue0;
uniform vec3 hue1;
uniform vec3 hue2;

vec3 sum = vec3(0.0);
float weight = 0.0;

// A light wandering round its home, on its own slow loop; thinking adds a faster swirl.
vec2 wander(vec2 home, float a, float b, float phase, vec2 reach) {
  vec2 drift = vec2(sin(time * a + phase), sin(time * b + phase * 1.7)) * reach;
  vec2 swirl = vec2(cos(time * 1.3 + phase * 3.1), sin(time * 1.7 + phase * 2.3)) * 0.07 * energy;
  return home + drift + swirl;
}

// Each light's color drifts toward the next hue and back.
vec3 hue(vec3 from, vec3 to, float phase) {
  return mix(from, to, 0.5 + 0.5 * sin(time * 0.17 + phase));
}

void light(vec2 at, vec3 color, float size, float amount) {
  vec2 d = (uv - at) * shape;
  float w = exp(-dot(d, d) / (size * size)) * amount;
  sum += color * w;
  weight += w;
}

void main() {
  light(wander(vec2(0.12, 0.08), 0.21, 0.17, 0.0, vec2(0.24, 0.12)), hue(hue0, hue1, 0.0), 0.5, 1.0);
  light(wander(vec2(0.88, 0.12), 0.16, 0.23, 1.3, vec2(0.22, 0.14)), hue(hue1, hue2, 1.1), 0.46, 1.0);
  light(wander(vec2(0.50, 0.42), 0.13, 0.19, 2.6, vec2(0.32, 0.18)), hue(hue2, hue0, 2.2), 0.42, 0.95);
  light(wander(vec2(0.10, 0.72), 0.19, 0.14, 3.9, vec2(0.20, 0.16)), hue(hue1, hue0, 3.3), 0.46, 1.0);
  light(wander(vec2(0.92, 0.78), 0.15, 0.21, 5.2, vec2(0.22, 0.14)), hue(hue0, hue2, 4.4), 0.46, 1.0);
  light(wander(vec2(0.50, 1.00), 0.18, 0.12, 6.5, vec2(0.30, 0.10)), hue(hue2, hue1, 5.5), 0.42, 0.9);
  light(pointer.xy, mix(hue1, hue2, 0.5 + 0.5 * sin(time * 0.6)), 0.3, pointer.z * 1.6);

  // A thin wash of the first hue under the lights, so no part of the screen is bare, and the
  // gaps between them read as brighter pools.
  vec3 color = (sum + hue0 * 0.08) / (weight + 0.08);
  float cover = 0.22 + 0.78 * (1.0 - exp(-weight * 1.6));
  float noise = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
  float alpha = clamp(cover * strength + noise / 255.0, 0.0, 1.0);
  gl_FragColor = vec4(color * alpha, alpha);
}`;

/** Of the screen's pixels, how many the field is drawn at. */
const SCALE = 0.3;

function rgb(hex: string): RGB {
  return [1, 3, 5].map((at) => parseInt(hex.slice(at, at + 2), 16) / 255) as RGB;
}

/** SwiftUI's easeInOut, near enough. */
function ease(progress: number): number {
  const k = Math.min(1, Math.max(0, progress));
  return k < 0.5 ? 4 * k * k * k : 1 - (-2 * k + 2) ** 3 / 2;
}

/** Draws into `host`'s canvas while `watch` is on screen. */
export function startAura(host: HTMLElement, accent: Accent, watch: Element = host): Aura {
  const canvas = host.querySelector("canvas");
  const still = matchMedia("(prefers-reduced-motion: reduce)");
  const dark = matchMedia("(prefers-color-scheme: dark)");
  const gl = canvas?.getContext("webgl", { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false, powerPreference: "low-power" });
  const program = gl && build(gl);
  if (!canvas || !gl || !program) {
    host.setAttribute("data-still", "");
    return { energy() {}, palette() {} };
  }

  const uniform = (name: string) => gl.getUniformLocation(program, name);
  const at = {
    time: uniform("time"),
    energy: uniform("energy"),
    strength: uniform("strength"),
    shape: uniform("shape"),
    pointer: uniform("pointer"),
    hues: [uniform("hue0"), uniform("hue1"), uniform("hue2")],
  };

  const huesOf = (name: Accent): RGB[] => {
    const scheme = dark.matches ? 1 : 0;
    return [name, COMPANION[name], THIRD[name]].map((each) => rgb(SYSTEM[each][scheme]));
  };

  let current = accent;
  let huesFrom = huesOf(accent);
  let huesTo = huesFrom;
  let huesStart = -Infinity;
  let energyFrom = 0;
  let energyTo = 0;
  let energyStart = 0;
  let energySeconds = 1.2;
  /** The field's own clock, which runs faster the more Dream is thinking. */
  let clock = 0;
  let last = 0;
  const pointer = { x: 0.5, y: 0.3, strength: 0, toX: 0.5, toY: 0.3, toStrength: 0 };
  let visible = true;
  let frame = 0;

  const resize = () => {
    const width = Math.max(1, Math.round(canvas.clientWidth * SCALE));
    const height = Math.max(1, Math.round(canvas.clientHeight * SCALE));
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
      gl.viewport(0, 0, width, height);
    }
  };

  const energyAt = (now: number) => energyFrom + (energyTo - energyFrom) * ease((now - energyStart) / (energySeconds * 1000));
  const huesAt = (now: number) => {
    const blend = still.matches ? 1 : ease((now - huesStart) / 1200);
    return huesFrom.map((color, index) => color.map((value, channel) => value + (huesTo[index][channel] - value) * blend) as RGB);
  };

  const draw = (now: number) => {
    resize();
    const energy = still.matches ? energyTo : energyAt(now);
    if (!still.matches) {
      const step = Math.min(0.05, last ? (now - last) / 1000 : 0);
      clock += step * (1.3 + 2.6 * energy);
      const follow = 1 - Math.exp(-step * 6);
      pointer.x += (pointer.toX - pointer.x) * follow;
      pointer.y += (pointer.toY - pointer.y) * follow;
      pointer.strength += (pointer.toStrength - pointer.strength) * (1 - Math.exp(-step * 3));
    }
    last = now;
    const width = canvas.clientWidth || 1;
    const height = canvas.clientHeight || 1;
    const shorter = Math.min(width, height, 900);
    gl.uniform1f(at.time, clock + 40);
    gl.uniform1f(at.energy, energy);
    gl.uniform1f(at.strength, (dark.matches ? 0.86 : 0.62) + 0.12 * energy);
    gl.uniform2f(at.shape, width / shorter, height / shorter);
    gl.uniform3f(at.pointer, pointer.x, pointer.y, pointer.strength);
    huesAt(now).forEach((color, index) => gl.uniform3fv(at.hues[index], color));
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  };

  const tick = (now: number) => {
    frame = 0;
    if (!visible || document.hidden) {
      last = 0;
      return;
    }
    draw(now);
    if (!still.matches) frame = requestAnimationFrame(tick);
  };

  const wake = () => {
    if (!frame) frame = requestAnimationFrame(tick);
  };

  // The light under the pointer: it follows a mouse while it's over the screen, and a finger
  // while it's down, then fades.
  const follow = (event: PointerEvent) => {
    if (still.matches) return;
    const box = host.getBoundingClientRect();
    const x = (event.clientX - box.left) / box.width;
    const y = (event.clientY - box.top) / box.height;
    const inside = x >= 0 && x <= 1 && y >= 0 && y <= 1;
    pointer.toX = x;
    pointer.toY = y;
    pointer.toStrength = inside && (event.pointerType === "mouse" || event.pressure > 0 || event.type === "pointerdown") ? 1 : 0;
  };
  addEventListener("pointermove", follow, { passive: true });
  addEventListener("pointerdown", follow, { passive: true });
  for (const name of ["pointerup", "pointercancel"]) {
    addEventListener(name, (event) => (event as PointerEvent).pointerType !== "mouse" && (pointer.toStrength = 0), { passive: true });
  }
  document.documentElement.addEventListener("pointerleave", () => (pointer.toStrength = 0));

  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    wake();
  }).observe(watch);
  new ResizeObserver(() => (still.matches ? draw(performance.now()) : wake())).observe(canvas);
  document.addEventListener("visibilitychange", wake);
  dark.addEventListener("change", () => {
    huesFrom = huesTo = huesOf(current);
    wake();
  });
  still.addEventListener("change", wake);

  draw(performance.now());
  host.setAttribute("data-live", "");
  wake();

  return {
    energy(target, seconds = 1.2) {
      const now = performance.now();
      energyFrom = energyAt(now);
      energyTo = target;
      energyStart = now;
      energySeconds = seconds;
      wake();
    },
    palette(next) {
      if (next === current) return;
      const now = performance.now();
      huesFrom = huesAt(now);
      huesTo = huesOf(next);
      huesStart = now;
      current = next;
      wake();
    },
  };
}

function build(gl: WebGLRenderingContext): WebGLProgram | null {
  const shader = (type: number, source: string) => {
    const made = gl.createShader(type);
    if (!made) return null;
    gl.shaderSource(made, source);
    gl.compileShader(made);
    return gl.getShaderParameter(made, gl.COMPILE_STATUS) ? made : null;
  };
  const vertex = shader(gl.VERTEX_SHADER, VERTEX);
  const fragment = shader(gl.FRAGMENT_SHADER, FRAGMENT);
  const program = gl.createProgram();
  if (!vertex || !fragment || !program) return null;
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
  gl.useProgram(program);
  // One triangle that covers the screen.
  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const position = gl.getAttribLocation(program, "position");
  gl.enableVertexAttribArray(position);
  gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
  return program;
}
