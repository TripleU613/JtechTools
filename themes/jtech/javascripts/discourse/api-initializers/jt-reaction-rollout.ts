import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import JtReactionRollout, {
  notePress,
} from "../components/jt-reaction-rollout.gts";
import { VANILLA_CLASS } from "../lib/jt-vanilla.ts";

interface PostMenuDag {
  add(key: string, value: unknown, position?: { after?: string }): void;
}

interface ReactionSettings {
  discourse_reactions_enabled?: boolean;
  discourse_reactions_enabled_reactions?: string;
  discourse_reactions_reaction_for_like?: string;
  discourse_reactions_allow_any_emoji?: boolean;
  enable_emoji?: boolean;
}

const ROW = "discourse-reactions-picker-container";
const GHOST = "jt-rx-ghost";
const SLIDE_MS = 220;
const EASE = "cubic-bezier(0.2, 0, 0, 1)";
// how much of the way to the wheel's target the row moves per 60th of a
// second: high enough to keep up, low enough to glide
const GLIDE = 0.22;

// How many buttons the plugin's picker shows: the enabled reactions, the
// like's own if it isn't among them, and the emoji picker when any emoji is
// allowed. The row is never wider than that.
function pickerSize(s: ReactionSettings): number {
  const reactions = (s.discourse_reactions_enabled_reactions || "")
    .split("|")
    .filter(Boolean);
  const like = s.discourse_reactions_reaction_for_like;
  return (
    reactions.length +
    (like && !reactions.includes(like) ? 1 : 0) +
    (s.discourse_reactions_allow_any_emoji ? 1 : 0)
  );
}

// Under a Discourse palette the plugin's own picker shows (jt-post-chrome).
function rolling(): boolean {
  return !document.documentElement.classList.contains(VANILLA_CLASS);
}

function stillMotion(): boolean {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

// Nothing of the row left: what it opens from and shuts to. Its padding
// goes too, and its frame (the picker around it) fades with its margin, or
// they'd snap away at the end.
const SHUT: Keyframe = {
  width: "0px",
  paddingLeft: "0px",
  paddingRight: "0px",
  opacity: 0,
};
const FRAME_SHUT: Keyframe = { marginRight: "0px", opacity: 0 };

// A row's width and how far it was scrolled, kept up to date while it's
// open: the plugin takes it away when it shuts, and the copy that slides
// shut in its place needs both.
const shown = new WeakMap<Element, { width: number; scroll: number }>();

// Which edge has more to scroll to: that edge fades (jt-post-chrome).
function markEdges(row: HTMLElement) {
  const end = row.scrollWidth - row.clientWidth;
  const before = row.scrollLeft > 1;
  const after = row.scrollLeft < end - 1;
  const more = before && after ? "both" : before ? "start" : after ? "end" : "";
  if (more) {
    row.dataset.jtMore = more;
  } else {
    delete row.dataset.jtMore;
  }
}

// The room the menu gives the row, rounded down to whole reactions so none
// is cut in half at its edge. Everything fitting, it's the row's own width.
function fitWidth(row: HTMLElement): number {
  const room = row.getBoundingClientRect().width;
  const cell =
    row.querySelector<HTMLElement>(".pickable-reaction")?.offsetWidth;
  if (!cell || row.scrollWidth <= row.clientWidth + 1) {
    return room;
  }
  const style = getComputedStyle(row);
  const chrome =
    parseFloat(style.paddingLeft) +
    parseFloat(style.paddingRight) +
    parseFloat(style.borderLeftWidth) +
    parseFloat(style.borderRightWidth);
  return Math.max(1, Math.floor((room - chrome) / cell)) * cell + chrome;
}

function open(row: HTMLElement, actions: Element) {
  // Shut again before it had slid away: it opens from where the copy was.
  const ghost = actions.querySelector<HTMLElement>(`.${GHOST}`);
  const from = ghost?.getBoundingClientRect().width ?? 0;
  ghost?.closest(".discourse-reactions-picker")?.remove();

  const width = fitWidth(row);
  row.style.width = `${width}px`;
  const state = { width, scroll: 0 };
  shown.set(row, state);
  markEdges(row);
  row.addEventListener(
    "scroll",
    () => {
      state.scroll = row.scrollLeft;
      markEdges(row);
    },
    { passive: true }
  );
  // On as the row appears, not when the pointer first comes over it: a
  // wheel turned before that would scroll the page instead.
  row.addEventListener(
    "wheel",
    (e) => {
      if (rolling()) {
        glide(row, e as WheelEvent);
      }
    },
    { passive: false }
  );

  if (!stillMotion()) {
    const timing = { duration: SLIDE_MS, easing: EASE };
    row.animate(
      [
        from ? { width: `${from}px` } : SHUT,
        { width: `${width}px`, opacity: 1 },
      ],
      timing
    );
    if (!from) {
      row.parentElement?.animate([FRAME_SHUT, { opacity: 1 }], timing);
    }
  }
}

// The plugin has just taken the picker away, row and all: a copy takes its
// place and slides shut, and the buttons beside it slide back with it.
function shut(picker: HTMLElement, parent: Node, next: Node | null) {
  const row = picker.querySelector<HTMLElement>(`.${ROW}`);
  const state = row && shown.get(row);
  if (!state || stillMotion() || !parent.isConnected) {
    return;
  }
  const copy = picker.cloneNode(true) as HTMLElement;
  copy.classList.remove("is-expanded");
  copy.setAttribute("aria-hidden", "true");
  copy.inert = true;
  // Never under the pointer: a pointer resting where the row was would land
  // on the copy, and the plugin would take that as pointing at its
  // reactions and open them again, right after one was picked.
  copy.style.pointerEvents = "none";
  const ghost = copy.querySelector<HTMLElement>(`.${ROW}`)!;
  ghost.classList.add(GHOST);
  parent.insertBefore(copy, next?.parentNode === parent ? next : null);
  ghost.scrollLeft = state.scroll;
  const timing: KeyframeAnimationOptions = {
    duration: SLIDE_MS,
    easing: EASE,
    fill: "forwards",
  };
  const slide = ghost.animate([{ width: `${state.width}px` }, SHUT], timing);
  copy.animate([{ opacity: 1 }, FRAME_SHUT], timing);
  slide.onfinish = () => copy.remove();
  slide.oncancel = () => copy.remove();
}

// The plugin renders the picker only while it's open. Each post's
// reactions someone has pointed at are watched for it coming and going:
// only those, and only for that.
const watched = new WeakSet<Element>();

function watch(actions: Element) {
  if (watched.has(actions)) {
    return;
  }
  watched.add(actions);
  new MutationObserver((records) => {
    if (!rolling()) {
      return;
    }
    for (const record of records) {
      record.addedNodes.forEach((node) => {
        const row =
          node instanceof HTMLElement && !node.inert
            ? node.querySelector<HTMLElement>(`.${ROW}:not(.${GHOST})`)
            : null;
        if (row) {
          open(row, actions);
        }
      });
      record.removedNodes.forEach((node) => {
        if (
          node instanceof HTMLElement &&
          node.classList.contains("discourse-reactions-picker") &&
          !node.inert
        ) {
          shut(node, record.target, record.nextSibling);
        }
      });
    }
  }).observe(actions, { childList: true, subtree: true });
}

// The wheel turned over a row: it glides there rather than jumping a notch
// at a time, and while the row can scroll at all it never scrolls the page.
const glides = new WeakMap<
  HTMLElement,
  { target: number; pos: number; frame: number }
>();

function glide(row: HTMLElement, wheel: WheelEvent) {
  if (Math.abs(wheel.deltaY) <= Math.abs(wheel.deltaX)) {
    return;
  }
  const end = row.scrollWidth - row.clientWidth;
  // every reaction already shows: nothing to scroll, the page has the wheel
  if (end < 1) {
    return;
  }
  // Pointing at the row, the wheel is the row's, even at an end: a turn too
  // many mustn't scroll the page out from under the reaction being aimed at.
  wheel.preventDefault();
  const state = glides.get(row) ?? { target: 0, pos: 0, frame: 0 };
  glides.set(row, state);
  if (!state.frame) {
    state.target = state.pos = row.scrollLeft;
  }
  const step = wheel.deltaY * (wheel.deltaMode === 1 ? 16 : 1);
  state.target = Math.min(end, Math.max(0, state.target + step));
  if (stillMotion()) {
    row.scrollLeft = state.target;
    return;
  }
  if (state.frame || Math.abs(state.target - state.pos) < 0.5) {
    return;
  }
  let last = performance.now();
  // The position is kept here, not read back: the browser rounds
  // scrollLeft, and a glide reading it back can stall short of its target.
  const frame = (now: number) => {
    const share = 1 - Math.pow(1 - GLIDE, (now - last) / (1000 / 60));
    last = now;
    state.pos += (state.target - state.pos) * share;
    if (Math.abs(state.target - state.pos) < 0.5 || !row.isConnected) {
      state.pos = state.target;
      state.frame = 0;
    } else {
      state.frame = requestAnimationFrame(frame);
    }
    row.scrollLeft = state.pos;
  };
  state.frame = requestAnimationFrame(frame);
}

// Each post's reactions are watched from the first time someone points
// anywhere in its menu.
function pointedAt(event: PointerEvent) {
  const target = event.target as Element | null;
  // anywhere in the menu: on touch screens the theme's own button opens it.
  // The heart's own: a post with reactions has the plugin's count first,
  // in reactions of its own that never open.
  const actions = target
    ?.closest?.(".post-controls")
    ?.querySelector(".discourse-reactions-reaction-button")
    ?.closest(".discourse-reactions-actions");
  if (actions) {
    watch(actions);
  }
}

// The Reactions plugin's picker as a row that rolls out sideways beside the
// heart (setting reaction_rollout) instead of a box over the post, in the
// theme's own look. The styles (jt-post-chrome) make the row; this slides it
// open and shut, glides the mouse wheel along it, and adds the button that
// opens it on touch screens (and lets it see presses before the plugin
// does).
export default apiInitializer((api) => {
  const siteSettings = api.container.lookup(
    "service:site-settings"
  ) as ReactionSettings;
  if (
    !settings.reaction_rollout ||
    !siteSettings.discourse_reactions_enabled ||
    !siteSettings.enable_emoji
  ) {
    return;
  }
  const root = document.documentElement;
  root.classList.add("jt-reaction-rollout");
  root.style.setProperty("--jt-rx-count", String(pickerSize(siteSettings)));

  api.registerValueTransformer(
    "post-menu-buttons",
    ({ value: dag }: { value: PostMenuDag }) => {
      dag.add("jt-reaction-rollout", JtReactionRollout, { after: "like" });
    }
  );

  // Capturing: the plugin renders its row in a microtask right after its own
  // pointerover handler, before the event would bubble up to here, and the
  // row has to be watched before it appears to slide open.
  document.addEventListener("pointerover", pointedAt, {
    capture: true,
    passive: true,
  });
  document.addEventListener(
    "pointerdown",
    (event) => {
      pointedAt(event);
      notePress(event);
    },
    { capture: true, passive: true }
  );
});
