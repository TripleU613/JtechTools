import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { next } from "@ember/runloop";
import { modifier } from "ember-modifier";
import { i18n } from "discourse-i18n";
import {
  type ListingChoice,
  type ListingComposer,
  type ListingSetup,
  listingSetup,
} from "../../lib/listing-format.ts";

interface ListingFormatFormSignature {
  Args: { outletArgs: { model?: ListingComposer | null } };
}

interface Row {
  field: string;
  id: string;
  choice: ListingChoice | null;
  editor: boolean;
  optional: boolean;
}

// Room the editor, its toolbar and the composer's header and footer need
// under the form.
const EDITOR_ROOM = 300;

// A box per section above the editor when replying in a listing topic, with
// options to pick for sections that have them (condition, pickup/shipping).
// The section names are fixed text, so the format can't be broken by
// editing it; the editor below fills the pictures section.
export default class ListingFormatForm extends Component<ListingFormatFormSignature> {
  // Ticks aren't tracked (they live on the composer), so a pick bumps this
  // to update the box's hint.
  @tracked picks = 0;

  // The form sits above the editor inside the composer's fixed height, so
  // a short composer would leave the editor no room and its toolbar over
  // the form. Grow it once to fit, the way dragging its edge would.
  fitComposer = modifier((element: HTMLElement) => {
    const root = document.documentElement;
    const current = parseInt(
      getComputedStyle(root).getPropertyValue("--composer-height"),
      10
    );
    const needed = Math.min(
      element.offsetHeight + EDITOR_ROOM,
      Math.round(window.innerHeight * 0.85)
    );
    if (current && current >= needed) {
      return;
    }
    const height = `${needed}px`;
    this.composer?.set("composerHeight", height);
    root.style.setProperty("--composer-height", height);
  });

  // Opening the composer mustn't bring up the keyboard: on a phone it covers
  // the form, and the editor (the pictures section) isn't where a listing
  // starts. Core focuses the editor as a reply opens, so until the person
  // taps or types in the composer, focus landing in it is dropped. With a
  // mouse there's no keyboard to pop up, so the first box takes focus.
  holdFocus = modifier(() => {
    const control = document.getElementById("reply-control");
    if (!control) {
      return;
    }
    const drop = (event: FocusEvent) => {
      (event.target as HTMLElement | null)?.blur?.();
    };
    const release = () => {
      control.removeEventListener("focusin", drop, true);
      control.removeEventListener("pointerdown", release, true);
      control.removeEventListener("keydown", release, true);
    };
    control.addEventListener("focusin", drop, true);
    control.addEventListener("pointerdown", release, true);
    control.addEventListener("keydown", release, true);

    next(() => {
      const focused = document.activeElement as HTMLElement | null;
      if (focused && control.contains(focused)) {
        focused.blur();
      }
      if (window.matchMedia("(pointer: fine)").matches) {
        release();
        control
          .querySelector<HTMLElement>(".listing-format-form__input")
          ?.focus();
      }
    });
    // Core's focus comes as the composer opens; after that, leave it be.
    const timer = setTimeout(release, 1500);
    return () => {
      clearTimeout(timer);
      release();
    };
  });

  // On a phone the form and the editor scroll together (see the stylesheet).
  // The browser scrolls only the line being typed into view, which can leave
  // a sliver of the editor above its toolbar. While the editor has focus,
  // and as the keyboard resizes the screen, keep the whole box in view.
  revealEditor = modifier(() => {
    const control = document.getElementById("reply-control");
    const phone = window.matchMedia("(width < 40rem)");
    if (!control) {
      return;
    }
    const reveal = () => {
      const focused = document.activeElement as HTMLElement | null;
      if (!phone.matches || !focused || !control.contains(focused)) {
        return;
      }
      const editor = focused.closest(".d-editor-textarea-wrapper");
      if (editor) {
        requestAnimationFrame(() =>
          editor.scrollIntoView({ block: "nearest" })
        );
      }
    };
    control.addEventListener("focusin", reveal);
    control.addEventListener("input", reveal);
    window.visualViewport?.addEventListener("resize", reveal);
    return () => {
      control.removeEventListener("focusin", reveal);
      control.removeEventListener("input", reveal);
      window.visualViewport?.removeEventListener("resize", reveal);
    };
  });

  placeholder = (row: Row): string => {
    void this.picks;
    const needs = this.composer
      ? (row.choice?.details ?? []).filter((option) =>
          this.composer?.listingPicked?.[row.field]?.includes(option)
        )
      : [];
    if (needs.length) {
      return i18n("listing_format.composer.details_needed", {
        options: needs.join(", "),
      });
    }
    return row.choice ? i18n("listing_format.composer.other_details") : "";
  };

  value = (field: string): string =>
    this.composer?.listingValues?.[field] ?? "";

  isPicked = (field: string, option: string): boolean =>
    this.composer?.listingPicked?.[field]?.includes(option) ?? false;

  optionId = (row: Row, option: string): string =>
    `${row.id}-${option.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`;

  get composer(): ListingComposer | null | undefined {
    return this.args.outletArgs?.model;
  }

  get setup(): ListingSetup | null {
    return this.composer ? listingSetup(this.composer) : null;
  }

  get rows(): Row[] {
    const setup = this.setup;
    if (!setup) {
      return [];
    }
    return setup.fields.map((field) => ({
      field,
      id: `listing-format-${field.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`,
      choice: setup.choices[field] ?? null,
      editor: field === setup.editorField,
      optional: setup.optional.includes(field),
    }));
  }

  @action
  update(field: string, event: Event) {
    const values = this.composer?.listingValues;
    if (values) {
      values[field] = (event.target as HTMLTextAreaElement).value;
    }
  }

  @action
  pick(row: Row, option: string, event: Event) {
    const picked = this.composer?.listingPicked;
    if (!picked) {
      return;
    }
    const checked = (event.target as HTMLInputElement).checked;
    const current = picked[row.field] ?? [];
    this.picks++;
    if (!row.choice?.multiple) {
      picked[row.field] = checked ? [option] : [];
    } else if (checked) {
      picked[row.field] = [...current, option];
    } else {
      picked[row.field] = current.filter((o) => o !== option);
    }
  }

  <template>
    {{#if this.rows.length}}
      <div
        class="listing-format-form"
        {{this.fitComposer}}
        {{this.holdFocus}}
        {{this.revealEditor}}
      >
        {{#each this.rows as |row|}}
          {{#if row.editor}}
            <p class="listing-format-form__editor-note">
              <span class="listing-format-form__label">{{row.field}}</span>
              {{#if row.optional}}
                <span class="listing-format-form__optional">{{i18n
                    "listing_format.composer.optional"
                  }}</span>
              {{/if}}
              {{i18n "listing_format.composer.in_editor"}}
            </p>
          {{else}}
            <div class="listing-format-form__section">
              <label
                class="listing-format-form__label"
                for={{row.id}}
              >{{row.field}}
                {{#if row.optional}}
                  <span class="listing-format-form__optional">{{i18n
                      "listing_format.composer.optional"
                    }}</span>
                {{/if}}
              </label>
              {{#if row.choice}}
                <div
                  aria-label={{row.field}}
                  class="listing-format-form__options"
                  role={{if row.choice.multiple "group" "radiogroup"}}
                >
                  {{#each row.choice.options as |option|}}
                    <label
                      class="listing-format-form__option"
                      for={{this.optionId row option}}
                    >
                      <input
                        checked={{this.isPicked row.field option}}
                        id={{this.optionId row option}}
                        name={{row.id}}
                        type={{if row.choice.multiple "checkbox" "radio"}}
                        {{on "change" (fn this.pick row option)}}
                      />
                      {{option}}
                    </label>
                  {{/each}}
                </div>
              {{/if}}
              <textarea
                class="listing-format-form__input"
                id={{row.id}}
                placeholder={{this.placeholder row}}
                rows="1"
                value={{this.value row.field}}
                {{on "input" (fn this.update row.field)}}
              ></textarea>
            </div>
          {{/if}}
        {{/each}}
      </div>
    {{/if}}
  </template>
}
