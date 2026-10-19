import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import { service } from "@ember/service";
import { type TrustedHTML, trustHTML } from "@ember/template";
import { modifier } from "ember-modifier";
import { themePrefix } from "virtual:theme";
import type KeyValueStore from "discourse/lib/key-value-store";
import { headerOffset } from "discourse/lib/offset-calculator";
import DiscourseURL from "discourse/lib/url";
import type KeyValueStoreService from "discourse/services/key-value-store";
import { and } from "discourse/truth-helpers";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import {
  depth,
  headingsInCooked,
  isMarked,
  MIN_HEADINGS,
  tocApplies,
  type TocHeading,
} from "../../lib/jt-toc.ts";

interface TocPost {
  post_number: number;
  cooked: string;
}

interface TocTopic {
  firstPostUrl: string;
  category?: { id?: number; parent_category_id?: number };
  postStream?: { posts?: TocPost[] };
}

interface JtTocSignature {
  Args: { outletArgs: { topic: TocTopic; renderTimeline: boolean } };
}

type KeyValueStoreProxy = KeyValueStoreService &
  Pick<KeyValueStore, "getItem" | "setItem" | "removeItem">;

const COLLAPSED_KEY = "jt-toc-collapsed";
// narrowest timeline column the contents are shown in
const MIN_COLUMN = 160;

// The first post's contents in the timeline's column on desktop (setting
// table_of_contents; it replaces DiscoTOC). Open, it takes the place of the
// timeline's scroller, whose column has no room for both, and keeps the
// buttons under it; "Contents" folds it away and the choice is remembered.
// While the first post is on screen the section being read is marked.
// Phones get the inline card instead (api-initializers/jt-toc).
export default class JtToc extends Component<JtTocSignature> {
  @service declare keyValueStore: KeyValueStoreProxy;

  @tracked collapsed: boolean;
  @tracked current: string | null = null;
  @tracked roomy = true;

  // template helpers: arrow functions, so they keep `this`
  isCurrent = (heading: TocHeading) => heading.anchor === this.current;
  indent = (heading: TocHeading): TrustedHTML =>
    trustHTML(`--jt-toc-depth: ${depth(heading, this.headings)}`);

  // Under a narrow window the timeline's column gets too slim for headings
  // (about 110px at 1000px): the post's own card shows instead.
  measure = modifier((probe: HTMLElement) => {
    const column = probe.closest(".topic-navigation");
    if (!column) {
      return;
    }
    const observer = new ResizeObserver(([entry]) => {
      const roomy = entry.contentRect.width >= MIN_COLUMN;
      if (roomy !== this.roomy) {
        this.roomy = roomy;
      }
    });
    observer.observe(column);
    return () => observer.disconnect();
  });

  trackReading = modifier(() => {
    let frame = 0;
    const update = () => {
      frame = 0;
      this.current = this.readingAnchor();
    };
    const onScroll = () => {
      frame ||= requestAnimationFrame(update);
    };
    update();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => {
      window.removeEventListener("scroll", onScroll);
      cancelAnimationFrame(frame);
    };
  });

  constructor(owner: Owner, args: JtTocSignature["Args"]) {
    super(owner, args);
    this.collapsed = !!this.keyValueStore.getItem(COLLAPSED_KEY);
  }

  get headings(): TocHeading[] {
    const { topic, renderTimeline } = this.args.outletArgs;
    const post = topic.postStream?.posts?.find((p) => p.post_number === 1);
    if (
      !renderTimeline ||
      !post?.cooked ||
      !tocApplies(isMarked(post.cooked), topic.category)
    ) {
      return [];
    }
    const headings = headingsInCooked(post.cooked);
    return headings.length >= MIN_HEADINGS ? headings : [];
  }

  // The last heading scrolled past, while the first post is still on screen.
  readingAnchor() {
    const cooked = document.querySelector("#post_1 .cooked");
    if (!cooked) {
      return null;
    }
    const line = headerOffset() + 24;
    if (cooked.getBoundingClientRect().bottom < line) {
      return null;
    }
    let reading: string | null = null;
    for (const heading of this.headings) {
      const el = this.headingElement(heading.anchor);
      if (el && el.getBoundingClientRect().top <= line) {
        reading = heading.anchor;
      }
    }
    return reading;
  }

  headingElement(anchor: string) {
    return document
      .querySelector(`#post_1 .cooked a.anchor[name="${CSS.escape(anchor)}"]`)
      ?.closest("h1, h2, h3, h4");
  }

  @action
  toggle() {
    this.collapsed = !this.collapsed;
    if (this.collapsed) {
      this.keyValueStore.setItem(COLLAPSED_KEY, "true");
    } else {
      this.keyValueStore.removeItem(COLLAPSED_KEY);
    }
  }

  <template>
    {{#if this.headings.length}}
      <div class="jt-toc-probe" {{this.measure}}></div>
    {{/if}}
    {{#if (and this.headings.length this.roomy)}}
      <nav
        aria-label={{i18n (themePrefix "jt.toc.title")}}
        class="jt-toc {{unless this.collapsed 'jt-toc--open'}}"
      >
        <button
          aria-expanded={{if this.collapsed "false" "true"}}
          class="btn btn-flat jt-toc__toggle"
          type="button"
          {{on "click" this.toggle}}
        >
          {{dIcon "list"}}
          <span>{{i18n (themePrefix "jt.toc.title")}}</span>
          {{dIcon (if this.collapsed "angle-right" "angle-down")}}
        </button>
        {{#unless this.collapsed}}
          <ol class="jt-toc__list" {{this.trackReading}}>
            {{#each this.headings as |heading|}}
              <li class="jt-toc__item" style={{this.indent heading}}>
                <a
                  aria-current={{if (this.isCurrent heading) "location"}}
                  class="jt-toc__link"
                  href="#{{heading.anchor}}"
                  {{on "click" (fn this.jump heading)}}
                >{{heading.text}}</a>
              </li>
            {{/each}}
          </ol>
        {{/unless}}
      </nav>
    {{/if}}
  </template>

  // Core's own in-page jump (header offset, images still loading); from
  // further down the topic, to the first post first.
  @action
  jump(heading: TocHeading, event: MouseEvent) {
    event.preventDefault();
    if (this.headingElement(heading.anchor)) {
      DiscourseURL.routeTo(`#${heading.anchor}`, {});
      return;
    }
    DiscourseURL.routeTo(this.args.outletArgs.topic.firstPostUrl, {
      skipIfOnScreen: false,
    });
    let tries = 0;
    const wait = setInterval(() => {
      if (this.headingElement(heading.anchor) || ++tries > 30) {
        clearInterval(wait);
        DiscourseURL.routeTo(`#${heading.anchor}`, {});
      }
    }, 100);
  }
}
