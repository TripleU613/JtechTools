import Component from "@glimmer/component";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import { emojiUnescape } from "discourse/lib/text";
import type SiteSettings from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";

type LevelSettings = SiteSettings & Record<string, string | boolean>;

const LEVELS = [0, 1, 2, 3, 4];

function split(value: unknown): string[] {
  return String(value ?? "")
    .split("|")
    .map((emoji) => emoji.trim())
    .filter(Boolean);
}

function emojis(list: string[]) {
  return htmlSafe(
    list.map((emoji) => emojiUnescape(`:${emoji}:`, {})).join(" ")
  );
}

interface Row {
  level: number;
  unlocks: ReturnType<typeof emojis> | null;
  has: ReturnType<typeof emojis>;
}

// The Reaction levels tab's table: what each trust level ends up with,
// worked out the same way as lib/discourse_reaction_levels.rb, live from
// the settings below it
export default class JtechReactionLevelsTable extends Component {
  @service declare siteSettings: LevelSettings;

  get on(): boolean {
    return !!this.siteSettings.jtech_reaction_levels_enabled;
  }

  get #lowest(): Map<string, number> {
    const map = new Map<string, number>();
    [...LEVELS]
      .reverse()
      .forEach((level) =>
        split(this.siteSettings[`jtech_reaction_levels_tl${level}`]).forEach(
          (emoji) => map.set(emoji, level)
        )
      );
    return map;
  }

  get #enabled(): string[] {
    const main = String(
      this.siteSettings.discourse_reactions_reaction_for_like ?? ""
    );
    return [
      ...new Set([
        main,
        ...split(this.siteSettings.discourse_reactions_enabled_reactions),
      ]),
    ].filter(Boolean);
  }

  get rows(): Row[] {
    const map = this.#lowest;
    const main = String(
      this.siteSettings.discourse_reactions_reaction_for_like
    );
    const enabled = this.#enabled;
    return LEVELS.map((level) => {
      const unlocks = enabled.filter(
        (emoji) => emoji !== main && map.get(emoji) === level
      );
      const has = enabled.filter((emoji) => {
        const at = map.get(emoji);
        return emoji === main || at === undefined || at <= level;
      });
      return {
        level,
        unlocks: unlocks.length ? emojis(unlocks) : null,
        has: emojis(has),
      };
    });
  }

  get notEnabled() {
    const enabled = new Set(this.#enabled);
    const missing = [...this.#lowest.keys()].filter((e) => !enabled.has(e));
    return missing.length ? emojis(missing) : null;
  }

  <template>
    <section class="jtech-reaction-levels admin-config-area-card">
      <h3>{{i18n "admin.jtech_tools.reaction_levels.title"}}</h3>
      {{#if this.on}}
        <p>{{i18n "admin.jtech_tools.reaction_levels.about"}}</p>
        <table>
          <thead>
            <tr>
              <th></th>
              <th>{{i18n "admin.jtech_tools.reaction_levels.unlocks"}}</th>
              <th>{{i18n "admin.jtech_tools.reaction_levels.has"}}</th>
            </tr>
          </thead>
          <tbody>
            {{#each this.rows as |row|}}
              <tr>
                <th>{{i18n
                    "admin.jtech_tools.reaction_levels.level"
                    level=row.level
                  }}</th>
                <td>{{#if row.unlocks}}{{row.unlocks}}{{else}}<span
                      class="jtech-reaction-levels__none"
                    >{{i18n
                        "admin.jtech_tools.reaction_levels.nothing"
                      }}</span>{{/if}}</td>
                <td>{{row.has}}</td>
              </tr>
            {{/each}}
          </tbody>
        </table>
        {{#if this.notEnabled}}
          <p class="jtech-reaction-levels__warn">{{i18n
              "admin.jtech_tools.reaction_levels.not_enabled"
            }}
            {{this.notEnabled}}</p>
        {{/if}}
      {{else}}
        <p>{{i18n "admin.jtech_tools.reaction_levels.off"}}</p>
      {{/if}}
    </section>
  </template>
}
