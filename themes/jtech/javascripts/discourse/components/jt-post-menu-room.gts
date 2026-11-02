import Component from "@glimmer/component";
import type Owner from "@ember/owner";
import { modifier } from "ember-modifier";
import type Site from "discourse/models/site";
import { buttonsIn, menuRoom } from "../lib/jt-post-menu-room.ts";

interface JtPostMenuRoomSignature {
  Args: { post: { id: number } };
  Element: HTMLElement;
}

interface Line {
  postId: number;
  line: HTMLElement;
  buttons: HTMLElement;
}

// The lines measured, by the parts the observer watches: the line for its
// width, the buttons' box for what's beside them
const lines = new Map<Element, Line>();
let observer: ResizeObserver | null = null;

// The line's width less what sits before the buttons (the reactions, the
// replies button), which the buttons that go into ⋯ don't change
function roomOf({ line, buttons }: Line): number {
  const style = getComputedStyle(line);
  const gap = parseFloat(style.columnGap) || 0;
  let width =
    line.clientWidth -
    parseFloat(style.paddingLeft) -
    parseFloat(style.paddingRight);
  for (const before of line.children) {
    const box = before.getBoundingClientRect().width;
    if (before !== buttons && box) {
      width -= box + gap;
    }
  }
  return buttonsIn(width);
}

// One observer for every post on the page. It reports after the browser's
// layout, so reading the lines here costs no layout of its own; and every
// line is read before any room changes. Measured one post at a time, each
// post's menu rendered again before the next was read, and every reading
// waited on a layout of the whole page.
function measure(entries: ResizeObserverEntry[]) {
  const changed = new Set<Line>();
  for (const entry of entries) {
    const line = lines.get(entry.target);
    if (line) {
      changed.add(line);
    }
  }
  const rooms = [...changed].map(
    (line) => [line.postId, roomOf(line)] as const
  );
  for (const [postId, room] of rooms) {
    if (menuRoom.get(postId) !== room) {
      menuRoom.set(postId, room);
    }
  }
}

// Measures how many buttons fit on a post's menu line on a phone. Again
// when the line or the room beside the buttons changes (turning the phone,
// a first reaction). Not shown: the menu renders it among its buttons
// (api-initializers/jt-phone-post-menu) to have a place on the page.
export default class JtPostMenuRoom extends Component<JtPostMenuRoomSignature> {
  static shouldRender(
    _args: unknown,
    _context: unknown,
    owner: Owner
  ): boolean {
    return !!(owner.lookup("service:site") as Site | undefined)?.mobileView;
  }

  measure = modifier((element: HTMLElement, [postId]: [number]) => {
    const line = element.closest<HTMLElement>("nav.post-controls");
    const buttons = line?.querySelector<HTMLElement>(":scope > .actions");
    if (!line || !buttons) {
      return;
    }
    const watched = { postId, line, buttons };
    observer ??= new ResizeObserver(measure);
    // observing reports each part once, which is the first reading
    for (const part of [line, buttons]) {
      lines.set(part, watched);
      observer.observe(part);
    }
    return () => {
      for (const part of [line, buttons]) {
        // a menu rendered again may already watch the same part
        if (lines.get(part) === watched) {
          lines.delete(part);
          observer?.unobserve(part);
        }
      }
    };
  });

  <template>
    <span
      class="jt-post-menu-room"
      hidden
      ...attributes
      {{this.measure @post.id}}
    ></span>
  </template>
}
