import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import { modifier } from "ember-modifier";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { emojiUnescape } from "discourse/lib/text";
import type SiteSettings from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";

type LevelSettings = SiteSettings & Record<string, string | boolean>;

// The columns: trust levels 0-4, then staff only. A reaction's level is
// the lowest column that can use it; everything from there to Staff can.
const COLUMNS = [0, 1, 2, 3, 4, 5];
const STAFF = 5;

function settingFor(level: number): string {
  return level === STAFF
    ? "jtech_reaction_levels_staff"
    : `jtech_reaction_levels_tl${level}`;
}

function split(value: unknown): string[] {
  return String(value ?? "")
    .split("|")
    .map((emoji) => emoji.trim())
    .filter(Boolean);
}

interface Row {
  emoji: string;
  image: ReturnType<typeof htmlSafe>;
  level: number;
  fixed: boolean;
}

// The Reaction levels tab: one row per reaction, a column per trust level
// up to Staff, and a box on each row's lowest level, with everything from
// there to Staff filled. Drag the box, click a column or use the arrow keys;
// each change saves the per-level lists it touches
// (lib/discourse_reaction_levels.rb reads them).
export default class JtechReactionLevelsGrid extends Component {
  @service declare siteSettings: LevelSettings;

  @tracked levels: Record<string, number> = {};
  @tracked saving = false;
  @tracked saved = false;

  // Dragging the box along the row (or a click on a column): the level
  // follows the pointer, and saves when it's let go
  dragTrack = modifier((track: HTMLElement, [row]: [Row]) => {
    if (row.fixed) {
      return;
    }
    const down = (event: PointerEvent) => {
      this.#dragging = row.emoji;
      track.setPointerCapture(event.pointerId);
      this.#follow(track, event, false);
    };
    const move = (event: PointerEvent) => {
      if (this.#dragging) {
        this.#follow(track, event, false);
      }
    };
    const up = (event: PointerEvent) => {
      if (this.#dragging) {
        this.#follow(track, event, true);
        this.#dragging = null;
      }
    };
    track.addEventListener("pointerdown", down);
    track.addEventListener("pointermove", move);
    track.addEventListener("pointerup", up);
    return () => {
      track.removeEventListener("pointerdown", down);
      track.removeEventListener("pointermove", move);
      track.removeEventListener("pointerup", up);
    };
  });

  #dragging: string | null = null;

  constructor(owner: Owner, args: object) {
    super(owner, args);
    this.levels = this.#readLevels();
  }

  get on(): boolean {
    return !!this.siteSettings.jtech_reaction_levels_enabled;
  }

  get main(): string {
    return String(
      this.siteSettings.discourse_reactions_reaction_for_like ?? ""
    );
  }

  get rows(): Row[] {
    const main = this.main;
    const enabled = [
      ...new Set([
        main,
        ...split(this.siteSettings.discourse_reactions_enabled_reactions),
      ]),
    ].filter(Boolean);
    return enabled.map((emoji) => ({
      emoji,
      image: htmlSafe(emojiUnescape(`:${emoji}:`, {})),
      level: emoji === main ? 0 : (this.levels[emoji] ?? 0),
      fixed: emoji === main,
    }));
  }

  get columns() {
    return COLUMNS.map((level) => ({
      level,
      label:
        level === STAFF
          ? i18n("admin.jtech_tools.reaction_levels.staff")
          : i18n("admin.jtech_tools.reaction_levels.tl", { level }),
      name: i18n(`admin.jtech_tools.reaction_levels.names.l${level}`),
    }));
  }

  @action
  cellClass(row: Row, level: number): string {
    return [
      "jtech-rl__cell",
      level >= row.level && "--on",
      level === row.level && "--min",
    ]
      .filter(Boolean)
      .join(" ");
  }

  @action
  key(row: Row, event: KeyboardEvent) {
    if (row.fixed) {
      return;
    }
    const step =
      {
        ArrowRight: 1,
        ArrowUp: 1,
        ArrowLeft: -1,
        ArrowDown: -1,
      }[event.key] ?? 0;
    let next = row.level + step;
    if (event.key === "Home") {
      next = 0;
    } else if (event.key === "End") {
      next = STAFF;
    } else if (!step) {
      return;
    }
    event.preventDefault();
    this.#set(row.emoji, Math.min(STAFF, Math.max(0, next)));
  }

  #follow(track: HTMLElement, event: PointerEvent, save: boolean) {
    const box = track.getBoundingClientRect();
    const share = (event.clientX - box.left) / box.width;
    const level = Math.min(
      STAFF,
      Math.max(0, Math.floor(share * COLUMNS.length))
    );
    const emoji = this.#dragging!;
    if (this.levels[emoji] !== level) {
      this.levels = { ...this.levels, [emoji]: level };
    }
    if (save) {
      this.#save();
    }
  }

  #set(emoji: string, level: number) {
    if ((this.levels[emoji] ?? 0) === level) {
      return;
    }
    this.levels = { ...this.levels, [emoji]: level };
    this.#save();
  }

  // Each level's list from the grid: a reaction listed under its level;
  // level 0 means not listed (open to everyone). Only lists that changed
  // are saved.
  async #save() {
    const lists: Record<number, string[]> = {};
    COLUMNS.forEach((level) => (lists[level] = []));
    Object.entries(this.levels).forEach(([emoji, level]) => {
      if (level > 0) {
        lists[level].push(emoji);
      }
    });
    lists[0] = [];

    this.saving = true;
    this.saved = false;
    try {
      for (const level of COLUMNS) {
        const name = settingFor(level);
        const value = lists[level].join("|");
        if (String(this.siteSettings[name] ?? "") !== value) {
          await ajax(`/admin/site_settings/${name}`, {
            type: "PUT",
            data: { [name]: value },
          });
          this.siteSettings[name] = value;
        }
      }
      this.saved = true;
    } catch (error) {
      popupAjaxError(error);
      this.levels = this.#readLevels();
    } finally {
      this.saving = false;
    }
  }

  // Each reaction's lowest level, from the settings
  #readLevels(): Record<string, number> {
    const map: Record<string, number> = {};
    [...COLUMNS]
      .reverse()
      .forEach((level) =>
        split(this.siteSettings[settingFor(level)]).forEach(
          (emoji) => (map[emoji] = level)
        )
      );
    return map;
  }

  <template>
    <section class="jtech-rl admin-config-area-card">
      <header class="jtech-rl__head">
        <h3>{{i18n "admin.jtech_tools.reaction_levels.title"}}</h3>
        <span class="jtech-rl__status" role="status">
          {{#if this.saving}}
            {{i18n "admin.jtech_tools.reaction_levels.saving"}}
          {{else if this.saved}}
            {{i18n "admin.jtech_tools.reaction_levels.saved"}}
          {{/if}}
        </span>
      </header>
      {{#unless this.on}}
        <p class="jtech-rl__off">{{i18n
            "admin.jtech_tools.reaction_levels.off"
          }}</p>
      {{/unless}}
      <p class="jtech-rl__about">{{i18n
          "admin.jtech_tools.reaction_levels.about"
        }}</p>

      <div class="jtech-rl__grid">
        <div class="jtech-rl__row --head">
          <span class="jtech-rl__name"></span>
          <div class="jtech-rl__track">
            {{#each this.columns as |column|}}
              <span class="jtech-rl__col">
                <b>{{column.label}}</b>
                <small>{{column.name}}</small>
              </span>
            {{/each}}
          </div>
        </div>

        {{#each this.rows key="emoji" as |row|}}
          <div class="jtech-rl__row {{if row.fixed '--fixed'}}">
            <span class="jtech-rl__name">
              <span class="jtech-rl__emoji">{{row.image}}</span>
              <code>{{row.emoji}}</code>
              {{#if row.fixed}}
                <small>{{i18n
                    "admin.jtech_tools.reaction_levels.always"
                  }}</small>
              {{/if}}
            </span>
            <div
              aria-disabled={{if row.fixed "true"}}
              aria-label={{row.emoji}}
              aria-valuemax="5"
              aria-valuemin="0"
              aria-valuenow={{row.level}}
              class="jtech-rl__track"
              role="slider"
              tabindex={{if row.fixed "-1" "0"}}
              {{on "keydown" (fn this.key row)}}
              {{this.dragTrack row}}
            >
              {{#each this.columns as |column|}}
                <span class={{this.cellClass row column.level}}></span>
              {{/each}}
            </div>
          </div>
        {{/each}}
      </div>
    </section>
  </template>
}
