import Component from "@glimmer/component";
import { modifier } from "ember-modifier";

const IDLE_MS = 900;
const MIN_THUMB = 36;

interface JtScrollbarSignature {
  Args: Record<string, never>;
}

interface ScrollbarDrag {
  y: number;
  scroll: number;
  ratio: number;
}

// The page's scrollbar as an overlay (macOS style): a thin pill over the
// right edge that takes no width, shows while scrolling or when the edge is
// hovered, and can be dragged or clicked. Native scrolling does all the
// work; this only mirrors it. Mouse/trackpad devices only — touch browsers
// already overlay their scrollbars. html.jt-overlay-scroll (which hides the
// native bar) exists only while this is mounted, so if it fails to render
// the native scrollbar is simply back.
export default class JtScrollbar extends Component<JtScrollbarSignature> {
  install = modifier((track: HTMLElement) => {
    if (!window.matchMedia("(hover: hover) and (pointer: fine)").matches) {
      return;
    }

    const root = document.documentElement;
    const thumb = track.firstElementChild as HTMLElement;
    let frame: number | null = null;
    let idle: ReturnType<typeof setTimeout> | null = null;
    let size = 0;
    let drag: ScrollbarDrag | null = null;

    root.classList.add("jt-overlay-scroll");

    const metrics = () => {
      const view = window.innerHeight;
      const max = root.scrollHeight - view;
      const room = track.clientHeight;
      size = Math.max(MIN_THUMB, Math.round((view / root.scrollHeight) * room));
      return { max, room };
    };

    // Each write restyles: only what changed is written. (classList.add
    // rewrites the attribute even when the class is already there.)
    let shownSize = -1;
    let shownOffset = -1;
    const render = () => {
      frame = null;
      const { max, room } = metrics();
      track.classList.toggle("--off", max <= 1);
      const offset = Math.round(
        max > 0 ? (window.scrollY / max) * (room - size) : 0
      );
      if (size !== shownSize) {
        thumb.style.height = `${size}px`;
        shownSize = size;
      }
      if (offset !== shownOffset) {
        thumb.style.transform = `translateY(${offset}px)`;
        shownOffset = offset;
      }
    };

    const schedule = () => {
      frame ??= requestAnimationFrame(render);
    };

    const wake = () => {
      if (!track.classList.contains("--active")) {
        track.classList.add("--active");
      }
      clearTimeout(idle);
      idle = setTimeout(() => {
        if (!drag) {
          track.classList.remove("--active");
        }
      }, IDLE_MS);
    };

    const onScroll = () => {
      schedule();
      wake();
    };

    const onPointerDown = (event: PointerEvent) => {
      if (event.button !== 0) {
        return;
      }
      event.preventDefault();
      const { max, room } = metrics();
      const ratio = max / Math.max(1, room - size);

      if (event.target !== thumb) {
        // Click on the track: centre the thumb on that spot
        const top = track.getBoundingClientRect().top;
        window.scrollTo({ top: (event.clientY - top - size / 2) * ratio });
      }

      drag = { y: event.clientY, scroll: window.scrollY, ratio };
      track.setPointerCapture(event.pointerId);
      track.classList.add("--dragging");
    };

    const onPointerMove = (event: PointerEvent) => {
      if (drag) {
        window.scrollTo({
          top: drag.scroll + (event.clientY - drag.y) * drag.ratio,
        });
      }
    };

    const onPointerUp = (event: PointerEvent) => {
      if (!drag) {
        return;
      }
      drag = null;
      track.releasePointerCapture?.(event.pointerId);
      track.classList.remove("--dragging");
      wake();
    };

    const resize = new ResizeObserver(schedule);
    resize.observe(document.body);
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", schedule);
    track.addEventListener("pointerdown", onPointerDown);
    track.addEventListener("pointermove", onPointerMove);
    track.addEventListener("pointerup", onPointerUp);
    track.addEventListener("pointercancel", onPointerUp);
    schedule();

    return () => {
      root.classList.remove("jt-overlay-scroll");
      resize.disconnect();
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", schedule);
      track.removeEventListener("pointerdown", onPointerDown);
      track.removeEventListener("pointermove", onPointerMove);
      track.removeEventListener("pointerup", onPointerUp);
      track.removeEventListener("pointercancel", onPointerUp);
      cancelAnimationFrame(frame);
      clearTimeout(idle);
    };
  });

  <template>
    <div aria-hidden="true" class="jt-scrollbar --off" {{this.install}}>
      <div class="jt-scrollbar__thumb"></div>
    </div>
  </template>
}
