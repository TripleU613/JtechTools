import Component from "@glimmer/component";
import { action } from "@ember/object";
import DMenu from "float-kit/components/d-menu";
import { settings, themePrefix } from "virtual:theme";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import {
  READER_SIZES,
  READER_WIDTHS,
  readerMode,
} from "../../lib/jt-reader.ts";

const WIDTH_NAMES = ["narrow", "medium", "wide", "widest"];

// Reader mode's switch at the top of the timeline (where the component had
// it), and while it's on, an "Aa" button beside it whose menu sets the text
// size, the column's width and the type, each a labelled row. Five bare
// icons under the switch said nothing about what they did.
export default class JtReaderMode extends Component {
  reader = readerMode;

  get show() {
    return settings.reader_mode;
  }

  get sizeLabel() {
    return `${Math.round(READER_SIZES[this.reader.size] * 100)}%`;
  }

  get widthLabel() {
    return i18n(
      themePrefix(`jt.reader.widths.${WIDTH_NAMES[this.reader.width]}`)
    );
  }

  get smallest() {
    return this.reader.size === 0;
  }

  get largest() {
    return this.reader.size === READER_SIZES.length - 1;
  }

  get narrowest() {
    return this.reader.width === 0;
  }

  get widest() {
    return this.reader.width === READER_WIDTHS.length - 1;
  }

  @action
  toggle() {
    this.reader.toggle();
  }

  @action
  smaller() {
    this.reader.step("size", -1);
  }

  @action
  larger() {
    this.reader.step("size", 1);
  }

  @action
  narrower() {
    this.reader.step("width", -1);
  }

  @action
  wider() {
    this.reader.step("width", 1);
  }

  @action
  sans() {
    if (this.reader.serif) {
      this.reader.toggleSerif();
    }
  }

  @action
  serif() {
    if (!this.reader.serif) {
      this.reader.toggleSerif();
    }
  }

  <template>
    {{#if this.show}}
      <div class="jt-reader-controls">
        <DButton
          aria-pressed={{if this.reader.on "true" "false"}}
          class="btn-default jt-reader-toggle {{if this.reader.on '--on'}}"
          @action={{this.toggle}}
          @icon="book-open"
          @title={{themePrefix "jt.reader.toggle"}}
        />
        {{#if this.reader.on}}
          <DMenu
            class="jt-reader-settings"
            @ariaLabel={{i18n (themePrefix "jt.reader.settings")}}
            @identifier="jt-reader-settings"
            @placement="bottom-start"
            @title={{i18n (themePrefix "jt.reader.settings")}}
            @triggerClass="btn-default jt-reader-settings__trigger"
          >
            <:trigger>
              <span aria-hidden="true" class="jt-reader-settings__aa">Aa</span>
            </:trigger>
            <:content>
              <div class="jt-reader-menu">
                <div class="jt-reader-menu__row">
                  <span class="jt-reader-menu__label">
                    {{i18n (themePrefix "jt.reader.text_size")}}
                  </span>
                  <div class="jt-reader-menu__stepper">
                    <DButton
                      class="btn-flat jt-reader-smaller"
                      @action={{this.smaller}}
                      @disabled={{this.smallest}}
                      @icon="minus"
                      @title={{themePrefix "jt.reader.smaller"}}
                    />
                    <span
                      class="jt-reader-menu__value"
                    >{{this.sizeLabel}}</span>
                    <DButton
                      class="btn-flat jt-reader-larger"
                      @action={{this.larger}}
                      @disabled={{this.largest}}
                      @icon="plus"
                      @title={{themePrefix "jt.reader.larger"}}
                    />
                  </div>
                </div>
                <div class="jt-reader-menu__row">
                  <span class="jt-reader-menu__label">
                    {{i18n (themePrefix "jt.reader.width")}}
                  </span>
                  <div class="jt-reader-menu__stepper">
                    <DButton
                      class="btn-flat jt-reader-narrower"
                      @action={{this.narrower}}
                      @disabled={{this.narrowest}}
                      @icon="minus"
                      @title={{themePrefix "jt.reader.narrower"}}
                    />
                    <span
                      class="jt-reader-menu__value"
                    >{{this.widthLabel}}</span>
                    <DButton
                      class="btn-flat jt-reader-wider"
                      @action={{this.wider}}
                      @disabled={{this.widest}}
                      @icon="plus"
                      @title={{themePrefix "jt.reader.wider"}}
                    />
                  </div>
                </div>
                <div class="jt-reader-menu__row">
                  <span class="jt-reader-menu__label">
                    {{i18n (themePrefix "jt.reader.font")}}
                  </span>
                  <div class="jt-reader-menu__segments">
                    <DButton
                      aria-pressed={{if this.reader.serif "false" "true"}}
                      class="btn-flat jt-reader-sans
                        {{unless this.reader.serif '--on'}}"
                      @action={{this.sans}}
                      @translatedLabel={{i18n (themePrefix "jt.reader.sans")}}
                    />
                    <DButton
                      aria-pressed={{if this.reader.serif "true" "false"}}
                      class="btn-flat jt-reader-serif
                        {{if this.reader.serif '--on'}}"
                      @action={{this.serif}}
                      @translatedLabel={{i18n
                        (themePrefix "jt.reader.serif_label")
                      }}
                    />
                  </div>
                </div>
              </div>
            </:content>
          </DMenu>
        {{/if}}
      </div>
    {{/if}}
  </template>
}
