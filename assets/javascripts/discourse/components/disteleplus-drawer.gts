import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { next } from "@ember/runloop";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import DButton from "discourse/components/d-button";
import bodyClass from "discourse/helpers/body-class";
import icon from "discourse/helpers/d-icon";
import DiscourseURL from "discourse/lib/url";
import type AppEventsService from "discourse/services/app-events";
import { i18n } from "discourse-i18n";
import type DisteleplusService from "../services/disteleplus.ts";
import DisteleplusConversation from "./disteleplus-conversation.gts";

interface DisteleplusDrawerSignature {
  Args: Record<string, never>;
}

interface ResizeStart {
  x: number;
  y: number;
  width: number;
  height: number;
}

// Bottom-right drawer, modelled on core Chat's ChatDrawer: fixed container
// above the footer, resizable from its top-left corner, collapsible to just
// its navbar by clicking the navbar, "open in full page" and close buttons.
export default class DisteleplusDrawer extends Component<DisteleplusDrawerSignature> {
  @service declare disteleplus: DisteleplusService;
  @service declare appEvents: AppEventsService;

  @tracked aboveComposer = false;

  resizeStart: ResizeStart | null = null;

  get style() {
    const { width, height } = this.disteleplus.drawerSize;
    return htmlSafe(`width:${width}px;height:${height}px`);
  }

  @action
  setup() {
    this.appEvents.on("composer:opened", this, this.checkComposer);
    this.appEvents.on("composer:closed", this, this.checkComposer);
    this.appEvents.on("composer:resized", this, this.checkComposer);
    this.checkComposer();
  }

  @action
  teardown() {
    this.appEvents.off("composer:opened", this, this.checkComposer);
    this.appEvents.off("composer:closed", this, this.checkComposer);
    this.appEvents.off("composer:resized", this, this.checkComposer);
  }

  // Lift the drawer above the reply composer when they would overlap.
  @action
  checkComposer() {
    next(() => {
      const composer = document.getElementById("reply-control");
      const open = composer && !composer.classList.contains("closed");
      if (!open) {
        this.aboveComposer = false;
        return;
      }
      const spaceToEnd =
        document.documentElement.clientWidth -
        composer.offsetLeft -
        composer.offsetWidth;
      this.aboveComposer = spaceToEnd < this.disteleplus.drawerSize.width + 20;
    });
  }

  @action
  toggleExpand() {
    this.disteleplus.toggleDrawerExpanded();
  }

  @action
  toggleSearch() {
    this.disteleplus.toggleSearch();
    if (this.disteleplus.searchOpen) {
      requestAnimationFrame(() =>
        document
          .querySelector<HTMLInputElement>(".disteleplus-search input")
          ?.focus()
      );
    }
  }

  @action
  close() {
    this.disteleplus.closeDrawer();
  }

  @action
  async openInFullPage() {
    this.disteleplus.prefersFullPage();
    this.disteleplus.closeDrawer();
    await new Promise<void>((resolve) => next(resolve));
    try {
      await DiscourseURL.routeTo("/disteleplus", {});
    } catch {
      // TransitionAborted is expected when another transition supersedes it.
    }
  }

  @action
  stop(event: Event) {
    event.stopPropagation();
  }

  // ── resize (top-left handle) ──────────────────────────────────────────────

  @action
  startResize(event: MouseEvent | TouchEvent) {
    event.preventDefault();
    const point: Touch | MouseEvent =
      (event as TouchEvent).touches?.[0] || (event as MouseEvent);
    const { width, height } = this.disteleplus.drawerSize;
    this.resizeStart = { x: point.pageX, y: point.pageY, width, height };
    window.addEventListener("mousemove", this.resize);
    window.addEventListener("touchmove", this.resize);
    window.addEventListener("mouseup", this.stopResize);
    window.addEventListener("touchend", this.stopResize);
  }

  @action
  resize(event: MouseEvent | TouchEvent) {
    if (!this.resizeStart) {
      return;
    }
    const point: Touch | MouseEvent =
      (event as TouchEvent).touches?.[0] || (event as MouseEvent);
    this.disteleplus.setDrawerSize({
      width: this.resizeStart.width - (point.pageX - this.resizeStart.x),
      height: this.resizeStart.height - (point.pageY - this.resizeStart.y),
    });
  }

  @action
  stopResize() {
    this.resizeStart = null;
    window.removeEventListener("mousemove", this.resize);
    window.removeEventListener("touchmove", this.resize);
    window.removeEventListener("mouseup", this.stopResize);
    window.removeEventListener("touchend", this.stopResize);
    this.checkComposer();
  }

  <template>
    {{#if this.disteleplus.isDrawerActive}}
      {{bodyClass "has-disteleplus-drawer"}}
      <div
        class="disteleplus-drawer-outlet-container
          {{if this.aboveComposer 'above-composer'}}"
        {{didInsert this.setup}}
        {{willDestroy this.teardown}}
      >
        <div
          class="disteleplus-drawer
            {{if
              this.disteleplus.isDrawerExpanded
              'is-expanded'
              'is-collapsed'
            }}"
          style={{this.style}}
        >
          <div class="disteleplus-drawer__container">
            {{! eslint-disable ember/template-no-invalid-interactive, ember/template-no-pointer-down-event-binding }}
            <div
              class="disteleplus-drawer__resizer"
              {{on "mousedown" this.startResize}}
              {{on "touchstart" this.startResize}}
            ></div>
            {{! eslint-enable ember/template-no-invalid-interactive, ember/template-no-pointer-down-event-binding }}

            {{! eslint-disable ember/template-no-invalid-interactive }}
            <div
              class="disteleplus-navbar-container"
              role="button"
              {{on "click" this.toggleExpand}}
            >
              <nav class="disteleplus-navbar">
                <div class="disteleplus-navbar__title">
                  {{icon "comments"}}
                  <span>{{i18n "disteleplus.title"}}</span>
                  {{#if this.disteleplus.unreadCount}}
                    <span class="disteleplus-navbar__unread">
                      {{this.disteleplus.unreadCount}}
                    </span>
                  {{/if}}
                </div>
                <div
                  class="disteleplus-navbar__actions"
                  {{on "click" this.stop}}
                >
                  {{#if this.disteleplus.isDrawerExpanded}}
                    <DButton
                      class="btn-transparent no-text
                        {{if this.disteleplus.searchOpen 'active'}}"
                      @action={{this.toggleSearch}}
                      @icon="magnifying-glass"
                      @title="disteleplus.search"
                    />
                  {{/if}}
                  <DButton
                    class="btn-transparent no-text"
                    @action={{this.toggleExpand}}
                    @icon={{if
                      this.disteleplus.isDrawerExpanded
                      "minus"
                      "angles-up"
                    }}
                    @title={{if
                      this.disteleplus.isDrawerExpanded
                      "disteleplus.collapse"
                      "disteleplus.expand"
                    }}
                  />
                  {{#if this.disteleplus.isDrawerExpanded}}
                    <DButton
                      class="btn-transparent no-text"
                      @action={{this.openInFullPage}}
                      @icon="discourse-expand"
                      @title="disteleplus.open_full_page"
                    />
                  {{/if}}
                  <DButton
                    class="btn-transparent no-text"
                    @action={{this.close}}
                    @icon="xmark"
                    @title="disteleplus.close"
                  />
                </div>
              </nav>
            </div>

            {{#if this.disteleplus.isDrawerExpanded}}
              <div class="disteleplus-drawer__content">
                <DisteleplusConversation @inDrawer={{true}} />
              </div>
            {{/if}}
          </div>
        </div>
      </div>
    {{/if}}
  </template>
}
