import Component from "@glimmer/component";
import type Owner from "@ember/owner";
import { modifier } from "ember-modifier";
import type Site from "discourse/models/site";
import { buttonsIn, menuRoom } from "../lib/jt-post-menu-room.ts";

interface JtPostMenuRoomSignature {
  Args: { post: { id: number } };
  Element: HTMLElement;
}

// Measures how many buttons fit on a post's menu line on a phone: the line's
// width less what sits before the buttons (the reactions, the replies
// button), which the buttons that go into ⋯ don't change. Again when the
// line or the room beside those changes (turning the phone, a first
// reaction). Not shown: the menu renders it among its buttons
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
    let frame = 0;
    const update = () => {
      frame = 0;
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
      const room = buttonsIn(width);
      if (menuRoom.get(postId) !== room) {
        menuRoom.set(postId, room);
      }
    };
    const soon = () => {
      frame ||= requestAnimationFrame(update);
    };
    // the line for its width, the buttons' box for what's beside them
    const observer = new ResizeObserver(soon);
    observer.observe(line);
    observer.observe(buttons);
    soon();
    return () => {
      observer.disconnect();
      cancelAnimationFrame(frame);
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
