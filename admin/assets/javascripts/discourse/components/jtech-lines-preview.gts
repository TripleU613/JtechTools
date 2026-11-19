import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

// The Ads tab's preview: a saved ad, or a draft that isn't saved, in the
// real ad space for this admin only (lib/discourse_jtech_ads/manager.rb).
export default class JtechLinesPreview extends Component {
  @tracked names: string[] = [];
  @tracked name = "";
  @tracked headline = "";
  @tracked card = "";
  @tracked busy = false;

  constructor(owner: Owner, args: object) {
    super(owner, args);
    this.#load();
  }

  get canPreview(): boolean {
    return !this.busy && (!!this.name || !!this.headline.trim());
  }

  @action
  pick(event: Event) {
    this.name = (event.target as HTMLSelectElement).value;
  }

  @action
  setHeadline(event: Event) {
    this.headline = (event.target as HTMLInputElement).value;
  }

  @action
  setCard(event: Event) {
    this.card = (event.target as HTMLTextAreaElement).value;
  }

  @action
  async open() {
    this.busy = true;
    // the window opens on the click, so it isn't blocked as a pop-up
    const tab = window.open("about:blank", "_blank");
    try {
      const draft = this.headline.trim();
      const result = await ajax("/jtech-lines/preview", {
        type: "POST",
        data: draft
          ? { name: "draft", headline: draft, card: this.card }
          : { name: this.name },
      });
      if (tab) {
        // the path, so it opens on whatever address this admin is using
        tab.location.href = result.path;
      }
    } catch (error) {
      tab?.close();
      popupAjaxError(error);
    } finally {
      this.busy = false;
    }
  }

  async #load() {
    try {
      const result = await ajax("/jtech-lines/preview");
      this.names = result.names;
    } catch (error) {
      popupAjaxError(error);
    }
  }

  <template>
    <section class="jtech-lines-preview admin-config-area-card">
      <h3>{{i18n "admin.jtech_tools.lines_preview.title"}}</h3>
      <p>{{i18n "admin.jtech_tools.lines_preview.about"}}</p>
      <label>
        {{i18n "admin.jtech_tools.lines_preview.saved"}}
        <select {{on "change" this.pick}}>
          <option value=""></option>
          {{#each this.names as |name|}}
            <option value={{name}}>{{name}}</option>
          {{/each}}
        </select>
      </label>
      <details>
        <summary>{{i18n "admin.jtech_tools.lines_preview.or_draft"}}</summary>
        <label>
          {{i18n "admin.jtech_tools.lines_preview.headline"}}
          <input type="text" {{on "input" this.setHeadline}} />
        </label>
        <label>
          {{i18n "admin.jtech_tools.lines_preview.card"}}
          <textarea rows="6" {{on "input" this.setCard}}></textarea>
        </label>
      </details>
      <DButton
        class="btn-primary"
        @action={{this.open}}
        @disabled={{not this.canPreview}}
        @icon="eye"
        @label="admin.jtech_tools.lines_preview.open"
      />
    </section>
  </template>
}

function not(value: unknown): boolean {
  return !value;
}
