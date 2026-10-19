// Things the hero (components/jt-hero) does that nobody is told about, for
// whoever plays with it:
//
// - The planet can be turned by hand: over the globe a mouse pointer becomes
//   a hand; drag it (or swipe it on a phone) and it coasts when let go.
// - A tap on the globe sends out a ping (lib/jt-planet).
// - A tap on the empty sky sends a shooting star from there.
// - ↑ ↑ ↓ ↓ ← → ← → B A, while the hero is on screen: a meteor shower,
//   every bright star flares and the planet whirls.
// - Left alone for a minute, a comet drifts across, once.
//
// Shooting stars and comets are elements added to the sky for as long as
// they fly. Their direction is set here, not in the stylesheet, so core's
// right-to-left stylesheet (Hebrew) doesn't mirror their heads to their
// tails. For people who ask for reduced motion only turning the planet by
// hand is left (it moves only as they move it).

import type JtPlanet from "./jt-planet.ts";

// One of the bright stars flaring: it swells, turns a quarter and fades
export const FLARE: Keyframe[] = [
  { opacity: 0, scale: "0.2", rotate: "0deg" },
  { opacity: 1, scale: "1", rotate: "45deg", offset: 0.5 },
  { opacity: 0, scale: "0.4", rotate: "90deg" },
];

const KONAMI = [
  "arrowup",
  "arrowup",
  "arrowdown",
  "arrowdown",
  "arrowleft",
  "arrowright",
  "arrowleft",
  "arrowright",
  "b",
  "a",
];

const IDLE_MS = 60 * 1000;
const MAX_STARS = 24;
const STAR_LENGTH = 110;
const COMET_LENGTH = 170;

// Taps on these do what they always do (and on text, select it)
const KEEP =
  "a, button, input, textarea, select, label, h1, p, form, .jt-hero__actions";

export interface QuirksOptions {
  planet: () => JtPlanet | null;
  calm: boolean;
}

interface Hold {
  id: number;
  start: number;
  last: number;
  moved: boolean;
}

function editable(target: EventTarget | null): boolean {
  return (
    target instanceof HTMLElement &&
    (target.isContentEditable ||
      ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName))
  );
}

export default class JtHeroQuirks {
  #hero: HTMLElement;
  #sky: HTMLElement | null;
  #planet: () => JtPlanet | null;
  #calm: boolean;
  #hold: Hold | null = null;
  #swallowClick = false;
  #keys = 0;
  #stars = 0;
  #lastActive = performance.now();
  #idle: ReturnType<typeof setInterval> | null = null;
  #hover: number | null = null;
  #hoverAt: [number, number] = [0, 0];

  #down = (event: PointerEvent) => {
    this.#swallowClick = false;
    if (event.button !== 0 || this.#keep(event.target)) {
      return;
    }
    const planet = this.#planet();
    if (!planet?.hit(event.clientX, event.clientY)) {
      return;
    }
    this.#hold = {
      id: event.pointerId,
      start: event.clientX,
      last: event.clientX,
      moved: false,
    };
    this.#hero.setPointerCapture(event.pointerId);
    this.#hero.classList.add("--grabbing");
    planet.grab();
    if (event.pointerType === "mouse") {
      event.preventDefault(); // no text selection while turning it
    }
  };

  #move = (event: PointerEvent) => {
    const hold = this.#hold;
    if (hold && event.pointerId === hold.id) {
      const dx = event.clientX - hold.last;
      hold.last = event.clientX;
      if (Math.abs(event.clientX - hold.start) > 5) {
        hold.moved = true;
      }
      if (hold.moved) {
        this.#planet()?.drag(dx);
      }
      return;
    }
    if (event.pointerType === "mouse") {
      this.#hoverAt = [event.clientX, event.clientY];
      this.#hover ??= requestAnimationFrame(this.#checkHover);
    }
  };

  // over the globe (and nothing that keeps its own pointer), a hand
  #checkHover = () => {
    this.#hover = null;
    const [x, y] = this.#hoverAt;
    const over =
      !this.#keep(document.elementFromPoint(x, y)) &&
      !!this.#planet()?.hit(x, y);
    this.#hero.classList.toggle("--on-planet", over);
  };

  #up = (event: PointerEvent) => {
    const hold = this.#hold;
    if (!hold || event.pointerId !== hold.id) {
      return;
    }
    this.#let(event);
    const planet = this.#planet();
    planet?.release();
    if (!hold.moved && !this.#calm) {
      planet?.ping();
    }
    // the click that follows belongs to the globe, not the sky
    this.#swallowClick = true;
  };

  #cancel = (event: PointerEvent) => {
    if (this.#hold && event.pointerId === this.#hold.id) {
      this.#let(event);
      this.#planet()?.release();
    }
  };

  #click = (event: MouseEvent) => {
    if (this.#swallowClick) {
      this.#swallowClick = false;
      return;
    }
    if (
      this.#calm ||
      this.#keep(event.target) ||
      window.getSelection()?.toString()
    ) {
      return;
    }
    this.#shoot(event.clientX, event.clientY);
  };

  #key = (event: KeyboardEvent) => {
    if (editable(event.target) || event.metaKey || event.ctrlKey) {
      return;
    }
    const key = event.key.toLowerCase();
    if (key === KONAMI[this.#keys]) {
      this.#keys++;
      if (this.#keys === KONAMI.length) {
        this.#keys = 0;
        if (this.#onScreen()) {
          this.#shower();
        }
      }
    } else {
      this.#keys = key === KONAMI[0] ? 1 : 0;
    }
  };

  #active = () => {
    this.#lastActive = performance.now();
  };

  #checkIdle = () => {
    if (
      performance.now() - this.#lastActive > IDLE_MS &&
      !document.hidden &&
      this.#onScreen()
    ) {
      this.#comet();
      this.#stopIdle(); // once a page view
    }
  };

  constructor(hero: HTMLElement, options: QuirksOptions) {
    this.#hero = hero;
    this.#sky = hero.querySelector<HTMLElement>(".jt-hero__sky");
    this.#planet = options.planet;
    this.#calm = options.calm;

    hero.addEventListener("pointerdown", this.#down);
    hero.addEventListener("pointermove", this.#move);
    hero.addEventListener("pointerup", this.#up);
    hero.addEventListener("pointercancel", this.#cancel);
    hero.addEventListener("click", this.#click);
    if (!this.#calm) {
      document.addEventListener("keydown", this.#key);
      for (const name of ["pointermove", "keydown", "scroll", "touchstart"]) {
        window.addEventListener(name, this.#active, { passive: true });
      }
      this.#idle = setInterval(this.#checkIdle, 5000);
    }
  }

  destroy() {
    const hero = this.#hero;
    hero.removeEventListener("pointerdown", this.#down);
    hero.removeEventListener("pointermove", this.#move);
    hero.removeEventListener("pointerup", this.#up);
    hero.removeEventListener("pointercancel", this.#cancel);
    hero.removeEventListener("click", this.#click);
    document.removeEventListener("keydown", this.#key);
    this.#stopIdle();
    if (this.#hover !== null) {
      cancelAnimationFrame(this.#hover);
    }
  }

  #stopIdle() {
    for (const name of ["pointermove", "keydown", "scroll", "touchstart"]) {
      window.removeEventListener(name, this.#active);
    }
    if (this.#idle) {
      clearInterval(this.#idle);
      this.#idle = null;
    }
  }

  #let(event: PointerEvent) {
    this.#hold = null;
    this.#hero.classList.remove("--grabbing");
    if (this.#hero.hasPointerCapture(event.pointerId)) {
      this.#hero.releasePointerCapture(event.pointerId);
    }
  }

  #keep(target: EventTarget | null): boolean {
    return target instanceof Element && !!target.closest(KEEP);
  }

  #onScreen(): boolean {
    const box = this.#hero.getBoundingClientRect();
    return box.bottom > 0 && box.top < window.innerHeight;
  }

  // A streak with its head at (x, y) on the page, flying down and to the
  // right, steeper or shallower each time
  #shoot(x: number, y: number, delay = 0) {
    const sky = this.#sky;
    if (!sky || this.#stars >= MAX_STARS) {
      return;
    }
    const box = sky.getBoundingClientRect();
    const angle = ((12 + Math.random() * 24) * Math.PI) / 180;
    const reach = 180 + Math.random() * 160;
    const star = document.createElement("span");
    star.className = "jt-hero__shoot";
    Object.assign(star.style, {
      left: `${x - box.left - STAR_LENGTH}px`,
      top: `${y - box.top}px`,
      width: `${STAR_LENGTH}px`,
      transformOrigin: "100% 50%",
      rotate: `${angle}rad`,
      // a glowing head on a fading tail
      background:
        "radial-gradient(circle at calc(100% - 2px) 50%, currentcolor 0 1px, color-mix(in srgb, currentcolor 40%, transparent) 1.6px, transparent 3px), linear-gradient(90deg, transparent, color-mix(in srgb, currentcolor 85%, transparent)) center / 100% 1px no-repeat",
    });
    sky.append(star);
    this.#stars++;
    const flight = star.animate(
      [
        { opacity: 0, translate: "0 0" },
        { opacity: 1, offset: 0.12 },
        {
          opacity: 0,
          translate: `${Math.cos(angle) * reach}px ${Math.sin(angle) * reach}px`,
        },
      ],
      {
        duration: 750 + Math.random() * 450,
        delay,
        easing: "cubic-bezier(0.2, 0.6, 0.4, 1)",
        fill: "backwards",
      }
    );
    const land = () => {
      star.remove();
      this.#stars--;
    };
    flight.onfinish = land;
    flight.oncancel = land;
  }

  // ↑ ↑ ↓ ↓ ← → ← → B A
  #shower() {
    const sky = this.#sky;
    if (!sky) {
      return;
    }
    const box = sky.getBoundingClientRect();
    for (let i = 0; i < 18; i++) {
      this.#shoot(
        box.left + box.width * (0.1 + Math.random() * 0.8),
        box.top + box.height * Math.random() * 0.6,
        i * 140 + Math.random() * 120
      );
    }
    const sparkles = sky.querySelectorAll<HTMLElement>(".jt-hero__sparkle");
    sparkles.forEach((sparkle, i) => {
      sparkle.animate(FLARE, {
        duration: 1600,
        delay: i * 300,
        easing: "ease-in-out",
      });
    });
    this.#planet()?.whirl(9);
  }

  // A comet: a bright head and a long tail, drifting across the whole sky
  #comet() {
    const sky = this.#sky;
    if (!sky) {
      return;
    }
    const width = sky.clientWidth;
    const height = sky.clientHeight;
    const from = [-COMET_LENGTH, height * 0.18];
    const to = [width + COMET_LENGTH, height * 0.52];
    const angle = Math.atan2(to[1] - from[1], to[0] - from[0]);
    const comet = document.createElement("span");
    comet.className = "jt-hero__visitor";
    Object.assign(comet.style, {
      left: `${from[0] - COMET_LENGTH}px`,
      top: `${from[1]}px`,
      width: `${COMET_LENGTH}px`,
      transformOrigin: "100% 50%",
      rotate: `${angle}rad`,
      background:
        "radial-gradient(circle at calc(100% - 4px) 50%, currentcolor 0 1.5px, color-mix(in srgb, currentcolor 35%, transparent) 2.5px, transparent 5px), linear-gradient(90deg, transparent, color-mix(in srgb, currentcolor 70%, transparent)) center / 100% 1.5px no-repeat",
    });
    sky.append(comet);
    const trip = comet.animate(
      [
        { opacity: 0, translate: "0 0" },
        { opacity: 1, offset: 0.1 },
        { opacity: 1, offset: 0.85 },
        { opacity: 0, translate: `${to[0] - from[0]}px ${to[1] - from[1]}px` },
      ],
      { duration: 9000, easing: "linear" }
    );
    trip.onfinish = () => comet.remove();
    trip.oncancel = () => comet.remove();
  }
}
