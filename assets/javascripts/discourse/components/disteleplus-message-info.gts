import Component from "@glimmer/component";
import { service } from "@ember/service";
import DModal from "discourse/components/d-modal";
import ageWithTooltip from "discourse/helpers/age-with-tooltip";
import icon from "discourse/helpers/d-icon";
import { getURLWithCDN } from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";
import DisteleplusService, {
  DisteleplusMessage,
} from "../services/disteleplus.ts";

const AVATAR_SIZE = 48;

interface DisteleplusMessageInfoSignature {
  Args: {
    model: { message: DisteleplusMessage };
    closeModal: () => void;
  };
}

interface InfoRow {
  username: string;
  name: string;
  avatarUrl: string | null;
  at: Date | null;
}

// WhatsApp-style message info: who has seen the message (read cursor passed
// it) and — for voice notes — who has listened, each with a timestamp.
// Opened by clicking the receipt chip on your own message.
export default class DisteleplusMessageInfo extends Component<DisteleplusMessageInfoSignature> {
  @service declare disteleplus: DisteleplusService;

  get message(): DisteleplusMessage {
    return this.args.model.message;
  }

  // Live: recomputed from the service so rows appear while the modal is
  // open. The author trivially saw their own message — leave them out.
  get seenBy(): InfoRow[] {
    const authorId = this.message.user?.id;
    return this.disteleplus
      .seenBy(this.message.id)
      .filter((state) => state.user_id !== authorId)
      .map((state) => ({
        username: state.username,
        name: state.name || state.username,
        avatarUrl: this.avatar(state.avatar_template),
        at: state.updated_at ? new Date(state.updated_at) : null,
      }));
  }

  get listenedBy(): InfoRow[] {
    const current =
      this.disteleplus.messages.find((m) => m.id === this.message.id) ||
      this.message;
    return (current.listened_by || []).map((user) => ({
      username: user.username,
      name: user.name || user.username,
      avatarUrl: this.avatar(user.avatar_template),
      at: user.listened_at ? new Date(user.listened_at) : null,
    }));
  }

  get hasVoiceNote(): boolean {
    return (this.message.uploads || []).some(
      (upload) => upload.kind === "audio"
    );
  }

  avatar(template: string | null): string | null {
    return template
      ? getURLWithCDN(template.replace("{size}", String(AVATAR_SIZE)))
      : null;
  }

  <template>
    <DModal
      class="disteleplus-message-info"
      @closeModal={{@closeModal}}
      @title={{i18n "disteleplus.message_info.title"}}
    >
      <:body>
        <h4>{{icon "check-double"}}
          {{i18n "disteleplus.message_info.seen"}}</h4>
        {{#if this.seenBy.length}}
          <ul class="disteleplus-message-info__list">
            {{#each this.seenBy as |reader|}}
              <li>
                {{#if reader.avatarUrl}}
                  <img alt="" src={{reader.avatarUrl}} />
                {{/if}}
                <span class="disteleplus-message-info__name">
                  {{reader.name}}
                </span>
                {{#if reader.at}}
                  <span class="disteleplus-message-info__when">
                    {{ageWithTooltip reader.at}}
                  </span>
                {{/if}}
              </li>
            {{/each}}
          </ul>
        {{else}}
          <p class="disteleplus-message-info__empty">
            {{i18n "disteleplus.message_info.nobody_yet"}}
          </p>
        {{/if}}

        {{#if this.hasVoiceNote}}
          <h4>{{icon "headphones"}}
            {{i18n "disteleplus.message_info.listened"}}</h4>
          {{#if this.listenedBy.length}}
            <ul class="disteleplus-message-info__list">
              {{#each this.listenedBy as |listener|}}
                <li>
                  {{#if listener.avatarUrl}}
                    <img alt="" src={{listener.avatarUrl}} />
                  {{/if}}
                  <span class="disteleplus-message-info__name">
                    {{listener.name}}
                  </span>
                  {{#if listener.at}}
                    <span class="disteleplus-message-info__when">
                      {{ageWithTooltip listener.at}}
                    </span>
                  {{/if}}
                </li>
              {{/each}}
            </ul>
          {{else}}
            <p class="disteleplus-message-info__empty">
              {{i18n "disteleplus.message_info.nobody_yet"}}
            </p>
          {{/if}}
        {{/if}}
      </:body>
    </DModal>
  </template>
}
