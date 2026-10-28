// The Aura (Dream/UI/Aura.swift), drawn with WebGL: a field of the page's two colors behind the
// top of the screen. At rest it drifts; while Dream thinks it spreads down the screen and swirls,
// its colors drifting into each other; while it writes it pulls back and flows.
//
// The app draws a 3 × 3 mesh gradient whose middle points move. This blends the same nine points,
// each with its own color and opacity, by distance. The field is soft, so it's drawn at a fraction
// of the screen's resolution and scaled up, which costs next to nothing. It stops drawing when it's
// off screen or the tab is hidden, and with Reduce Motion it's drawn once and holds still.

import { COMPANION, SYSTEM, type Accent } from "../lib/palette";

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
uniform float breath;
uniform vec3 accent;
uniform vec3 companion;

// Speeds are fixed and only amplitudes change, so nothing jumps when the energy does.
float offset(float phase) {
  float drift = sin(time * 0.22 + phase) * 0.06;
  float flow = sin(time * 1.1 + phase * 2.3) * 0.11 * energy;
  float swirl = sin(time * 2.4 + phase * 3.7) * 0.06 * energy * energy;
  return drift + flow + swirl;
}

// While thinking, each point drifts between the two colors on its own rhythm.
vec3 tint(float index, vec3 base, vec3 other) {
  return mix(base, other, energy * energy * (sin(time * 0.9 + index * 1.7) + 1.0) * 0.5);
}

void point(inout vec4 sum, inout float total, vec2 at, vec3 color, float opacity) {
  vec2 d = uv - at;
  float weight = exp(-dot(d, d) * 7.0);
  sum += vec4(color * opacity, opacity) * weight;
  total += weight;
}

void main() {
  vec4 sum = vec4(0.0);
  float total = 0.0;
  point(sum, total, vec2(0.0, 0.0), tint(0.0, accent, companion), 1.0);
  point(sum, total, vec2(0.5 + offset(0.0), 0.0), tint(1.0, companion, accent), 0.9);
  point(sum, total, vec2(1.0, 0.0), tint(2.0, accent, companion), 0.55);
  point(sum, total, vec2(0.0, 0.5 + offset(1.0)), tint(3.0, companion, accent), 0.45);
  point(sum, total, vec2(0.5 + offset(2.0), 0.5 + offset(3.0)), tint(4.0, accent, companion), 0.35);
  point(sum, total, vec2(1.0, 0.5 + offset(4.0)), tint(5.0, companion, accent), 0.5);
  point(sum, total, vec2(0.0, 1.0), vec3(0.0), 0.0);
  point(sum, total, vec2(0.5 + offset(5.0), 1.0), vec3(0.0), 0.0);
  point(sum, total, vec2(1.0, 1.0), vec3(0.0), 0.0);
  vec4 field = sum / total;

  // Reach: the light spreads further down the screen the more Dream is thinking.
  float near = 0.25 + 0.25 * energy;
  float far = 0.6 + 0.4 * energy;
  float reach = uv.y < near ? mix(1.0, 0.7, uv.y / near) : mix(0.7, 0.0, clamp((uv.y - near) / (far - near), 0.0, 1.0));

  vec3 color = field.a > 0.0001 ? field.rgb / field.a : vec3(0.0);
  color = clamp(color + breath, 0.0, 1.0);
  // A little noise, so a deep gradient doesn't band.
  float noise = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
  float alpha = clamp(field.a * strength * reach + noise / 255.0, 0.0, 1.0);
  gl_FragColor = vec4(color * alpha, alpha);
}`;

/** Of the screen's pixels, how many the field is drawn at. */
const SCALE = 0.35;

function rgb(hex: string): RGB {
  return [1, 3, 5].map((at) => parseInt(hex.slice(at, at + 2), 16) / 255) as RGB;
}

/** SwiftUI's easeInOut, near enough. */
function ease(progress: number): number {
  const k = Math.min(1, Math.max(0, progress));
  return k < 0.5 ? 4 * k * k * k : 1 - (-2 * k + 2) ** 3 / 2;
}

export function startAura(host: HTMLElement, accent: Accent): Aura {
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
    breath: uniform("breath"),
    accent: uniform("accent"),
    companion: uniform("companion"),
  };

  const colorsOf = (name: Accent): [RGB, RGB] => {
    const scheme = dark.matches ? 1 : 0;
    return [rgb(SYSTEM[name][scheme]), rgb(SYSTEM[COMPANION[name]][scheme])];
  };

  let current = accent;
  let colorsFrom = colorsOf(accent);
  let colorsTo = colorsFrom;
  let colorsStart = 0;
  let energyFrom = 0.12;
  let energyTo = 0.12;
  let energyStart = 0;
  let energySeconds = 1.2;
  const born = performance.now();
  let visible = true;
  let frame = 0;
  let drawn = 0;

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

  const draw = (now: number) => {
    resize();
    const energy = still.matches ? energyTo : energyAt(now);
    const blend = still.matches ? 1 : ease((now - colorsStart) / 1200);
    const mixed = (index: 0 | 1) => colorsFrom[index].map((value, channel) => value + (colorsTo[index][channel] - value) * blend) as RGB;
    const time = still.matches ? 0 : (now - born) / 1000;
    gl.uniform1f(at.time, time);
    gl.uniform1f(at.energy, energy);
    gl.uniform1f(at.strength, (dark.matches ? 0.72 : 0.42) + 0.15 * energy);
    gl.uniform1f(at.breath, Math.sin(time * 1.3) * (dark.matches ? 0.05 : 0.03) * energy * energy);
    gl.uniform3fv(at.accent, mixed(0));
    gl.uniform3fv(at.companion, mixed(1));
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    drawn = now;
  };

  const tick = (now: number) => {
    frame = 0;
    if (!visible || document.hidden) return;
    // At rest the field barely moves, so it's drawn less often.
    const busy = energyAt(now) > 0.2 || now - colorsStart < 1300 || now - energyStart < energySeconds * 1000;
    if (now - drawn >= (busy ? 0 : 1000 / 24) - 2) draw(now);
    if (!still.matches) frame = requestAnimationFrame(tick);
  };

  const wake = () => {
    if (!frame) frame = requestAnimationFrame(tick);
  };

  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    wake();
  }).observe(host);
  new ResizeObserver(() => (still.matches ? draw(performance.now()) : wake())).observe(canvas);
  document.addEventListener("visibilitychange", wake);
  dark.addEventListener("change", () => {
    colorsFrom = colorsTo = colorsOf(current);
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
      const blend = ease((now - colorsStart) / 1200);
      colorsFrom = colorsFrom.map((color, index) => color.map((value, channel) => value + (colorsTo[index][channel] - value) * blend)) as [RGB, RGB];
      colorsTo = colorsOf(next);
      colorsStart = now;
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
