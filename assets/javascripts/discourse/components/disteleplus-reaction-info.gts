import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DModal from "discourse/components/d-modal";
import ageWithTooltip from "discourse/helpers/age-with-tooltip";
import icon from "discourse/helpers/d-icon";
import { getURLWithCDN } from "discourse/lib/get-url";
import { emojiUrlFor } from "discourse/lib/text";
import { i18n } from "discourse-i18n";
import DisteleplusService, {
  DisteleplusCurrentUser,
  DisteleplusMessage,
} from "../services/disteleplus.ts";

const AVATAR_SIZE = 48;

interface DisteleplusReactionInfoSignature {
  Args: {
    model: {
      message: DisteleplusMessage;
      react: (emoji: string) => void;
      pick: (event: MouseEvent) => void;
    };
    closeModal: () => void;
  };
}

interface ReactionChip {
  emoji: string;
  url: string | undefined;
  count: number;
  reacted: boolean;
}

interface ReactorRow {
  username: string;
  name: string;
  avatarUrl: string | null;
  emoji: string;
  emojiUrl: string | undefined;
  at: Date | null;
  mine: boolean;
}

// WhatsApp-style reactions sheet: chips of the message's reactions (click
// one to add yours — or remove it if it's already yours), a smiley-plus for
// a brand-new emoji, and below them every reactor with their emoji and when.
// Your own rows also remove on click. Opened by clicking a reaction chip.
export default class DisteleplusReactionInfo extends Component<DisteleplusReactionInfoSignature> {
  @service declare disteleplus: DisteleplusService;
  @service declare currentUser: DisteleplusCurrentUser | null;

  // Read the message back from the service so the sheet stays live while
  // open (bus updates replace message objects wholesale).
  get message(): DisteleplusMessage {
    return (
      this.disteleplus.messages.find(
        (m) => m.id === this.args.model.message.id
      ) || this.args.model.message
    );
  }

  get title(): string {
    return i18n("disteleplus.reaction_info.title", {
      count: this.totalCount,
    });
  }

  get removeHint(): string {
    return i18n("disteleplus.reaction_info.remove_hint");
  }

  get totalCount(): number {
    return (this.message.reactions || []).reduce(
      (sum, reaction) => sum + (reaction.count || 0),
      0
    );
  }

  get chips(): ReactionChip[] {
    return (this.message.reactions || []).map((reaction) => ({
      emoji: reaction.emoji,
      url: reaction.url || emojiUrlFor(reaction.emoji),
      count: reaction.count,
      reacted: reaction.reacted,
    }));
  }

  get rows(): ReactorRow[] {
    const rows: ReactorRow[] = [];
    (this.message.reactions || []).forEach((reaction) => {
      (reaction.users || []).forEach((user) => {
        if (!user) {
          return;
        }
        rows.push({
          username: user.username,
          name: user.name || user.username,
          avatarUrl: user.avatar_template
            ? getURLWithCDN(
                user.avatar_template.replace("{size}", String(AVATAR_SIZE))
              )
            : null,
          emoji: reaction.emoji,
          emojiUrl: reaction.url || emojiUrlFor(reaction.emoji),
          at: user.reacted_at ? new Date(user.reacted_at) : null,
          mine: user.id === this.currentUser?.id,
        });
      });
    });
    return rows.sort((a, b) => (b.at?.getTime() || 0) - (a.at?.getTime() || 0));
  }

  // A chip toggles your own reaction of that emoji; the sheet stays open so
  // the change shows up live in the list.
  @action
  chipClick(chip: ReactionChip) {
    this.args.model.react(chip.emoji);
  }

  @action
  rowClick(row: ReactorRow) {
    if (!row.mine) {
      return;
    }
    this.args.model.react(row.emoji);
  }

  @action
  addReaction(event: MouseEvent) {
    this.args.closeModal();
    this.args.model.pick(event);
  }

  <template>
    <DModal
      class="disteleplus-reaction-info"
      @closeModal={{@closeModal}}
      @title={{this.title}}
    >
      <:body>
        <div class="disteleplus-reaction-info__bar">
          <button
            class="is-more"
            title={{i18n "disteleplus.reaction_info.add"}}
            type="button"
            {{on "click" this.addReaction}}
          >
            {{icon "face-smile"}}
            {{icon "plus"}}
          </button>
          {{#each this.chips as |chip|}}
            <button
              class={{if chip.reacted "is-reacted"}}
              title=":{{chip.emoji}}:"
              type="button"
              {{on "click" (fn this.chipClick chip)}}
            >
              {{#if chip.url}}
                <img alt=":{{chip.emoji}}:" class="emoji" src={{chip.url}} />
              {{else}}
                <span>:{{chip.emoji}}:</span>
              {{/if}}
              <span class="disteleplus-reaction-info__chip-count">
                {{chip.count}}
              </span>
            </button>
          {{/each}}
        </div>
        <ul class="disteleplus-reaction-info__list">
          {{#each this.rows as |row|}}
            <li>
              <button
                class={{if row.mine "is-mine"}}
                disabled={{unless row.mine "disabled"}}
                title={{if row.mine this.removeHint}}
                type="button"
                {{on "click" (fn this.rowClick row)}}
              >
                {{#if row.avatarUrl}}
                  <img alt="" class="avatar" src={{row.avatarUrl}} />
                {{/if}}
                <span class="disteleplus-reaction-info__who">
                  <span class="disteleplus-reaction-info__name">
                    {{row.name}}
                  </span>
                </span>
                {{#if row.at}}
                  <span class="disteleplus-reaction-info__when">
                    {{ageWithTooltip row.at}}
                  </span>
                {{/if}}
                {{#if row.emojiUrl}}
                  <img
                    alt=":{{row.emoji}}:"
                    class="emoji"
                    src={{row.emojiUrl}}
                  />
                {{else}}
                  <span>:{{row.emoji}}:</span>
                {{/if}}
              </button>
            </li>
          {{/each}}
        </ul>
      </:body>
    </DModal>
  </template>
}
