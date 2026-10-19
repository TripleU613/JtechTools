import Component from "@glimmer/component";
import icon from "discourse/helpers/d-icon";
import { emojiUrlFor } from "discourse/lib/text";
import { CUSTOM, kindInfo, type ReqpmKindInfo } from "../lib/reqpm-kinds.ts";

interface ReqpmKindIconSignature {
  Args: { kind: string | null | undefined; emoji?: string | null };
}

// Round badge for a contact kind: the platform's icon, or the emoji the
// user picked for a custom one.
export default class ReqpmKindIcon extends Component<ReqpmKindIconSignature> {
  get info(): ReqpmKindInfo {
    return kindInfo(this.args.kind);
  }

  get emojiUrl(): string | null {
    if (this.args.kind !== CUSTOM || !this.args.emoji) {
      return null;
    }
    return emojiUrlFor(this.args.emoji);
  }

  <template>
    <span
      aria-hidden="true"
      class="reqpm-kind-icon reqpm-kind-icon--{{this.info.id}}"
    >
      {{#if this.emojiUrl}}
        <img alt="" class="emoji" src={{this.emojiUrl}} />
      {{else}}
        {{icon this.info.icon}}
      {{/if}}
    </span>
  </template>
}
