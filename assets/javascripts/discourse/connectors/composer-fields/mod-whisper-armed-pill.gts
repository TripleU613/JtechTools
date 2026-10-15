import Component from "@glimmer/component";
import { action, get } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import { i18n } from "discourse-i18n";
import type { WhisperTargetComposer } from "../../components/mod-whisper-target-modal";
import { setPendingWhisperEdit } from "../../lib/mod-whisper-pending";
import type { WhisperTargetBadge } from "../../lib/mod-whisper-reply-audience";

interface ModWhisperArmedPillSignature {
  Args: { outletArgs: { model?: WhisperTargetComposer | null } };
}

// Renders a pill above the composer body whenever a whisper is armed. The
// pill's DOM presence ALSO triggers the tint on the surrounding composer
// fields, via `.composer-fields:has(...)` in SCSS.
//
// An armed whisper with zero targets is a staff-only whisper-back; the pill
// still shows (it is the signal a whisper is armed at all).
export default class ModWhisperArmedPill extends Component<ModWhisperArmedPillSignature> {
  // an admin's whisper with no targets reaches admins only
  @service declare currentUser: { admin?: boolean } | null;

  get composer(): WhisperTargetComposer | null | undefined {
    return this.args.outletArgs?.model;
  }

  // `modWhisperArmed` / `modWhisperTargetUsernames` are set on the composer
  // model with Ember's `set`. They are not @tracked native fields, so they
  // must be READ with Ember's `get` — that consumes the classic property tag
  // that `set` dirties. A plain dotted access would never re-render the pill.
  //
  // The boolean armed flag — not the target list — is the signal. An armed
  // whisper with zero targets is a staff-only whisper-back; the pill must
  // still show for it.
  get armed(): boolean {
    const composer = this.composer;
    if (!composer) {
      return false;
    }
    return get(composer, "modWhisperArmed") === true;
  }

  get staffOnly(): boolean {
    return (
      this.usernames.length === 0 &&
      this.groupNames.length === 0 &&
      this.badges.length === 0
    );
  }

  get usernames(): string[] {
    const composer = this.composer;
    return composer ? get(composer, "modWhisperTargetUsernames") || [] : [];
  }

  get groupNames(): string[] {
    const composer = this.composer;
    return composer ? get(composer, "modWhisperTargetGroupNames") || [] : [];
  }

  get badges(): WhisperTargetBadge[] {
    const composer = this.composer;
    return composer ? get(composer, "modWhisperTargetBadges") || [] : [];
  }

  // A separator is needed before a group entry whenever anything (a user, or
  // an earlier group) was already rendered ahead of it.
  @action
  needsSep(groupIndex: number): boolean {
    return this.usernames.length > 0 || groupIndex > 0;
  }

  @action
  needsBadgeSep(badgeIndex: number): boolean {
    return (
      this.usernames.length > 0 || this.groupNames.length > 0 || badgeIndex > 0
    );
  }

  @action
  clearArmed() {
    const composer = this.composer;
    if (!composer) {
      return;
    }
    composer.set("modWhisperArmed", false);
    composer.set("modWhisperTargetUserIds", null);
    composer.set("modWhisperTargetUsernames", null);
    composer.set("modWhisperTargets", null);
    composer.set("modWhisperTargetGroupIds", null);
    composer.set("modWhisperTargetGroupNames", null);
    composer.set("modWhisperTargetGroups", null);
    composer.set("modWhisperTargetBadgeIds", null);
    composer.set("modWhisperTargetBadges", null);
    // On an EDIT the composer state alone isn't enough — record a pending
    // disarm so the mod-whisper initializer PUTs the "remove whisper"
    // intent to the server once `composer:saved` confirms the edit save.
    // Same disarm-on-edit gap the modal's Clear button covers.
    if (composer.editingPost && composer.post?.id) {
      setPendingWhisperEdit({
        postId: composer.post.id,
        state: {
          mod_whisper: false,
          mod_whisper_target_user_ids: [],
          mod_whisper_target_group_ids: [],
          mod_whisper_target_badge_ids: [],
        },
      });
    }
  }

  <template>
    {{#if this.armed}}
      <div class="mod-whisper-armed-pill" role="status">
        {{#if this.staffOnly}}
          <span class="mod-whisper-armed-pill__label">
            {{#if this.currentUser.admin}}
              {{i18n "discourse_mod_categories.whisper.armed_pill_admins_only"}}
            {{else}}
              {{i18n "discourse_mod_categories.whisper.armed_pill_staff_only"}}
            {{/if}}
          </span>
        {{else}}
          <span class="mod-whisper-armed-pill__label">
            {{i18n "discourse_mod_categories.whisper.armed_pill_prefix"}}
          </span>
          <span class="mod-whisper-armed-pill__users">
            {{#each this.usernames as |name index|}}
              {{#if index}}<span class="mod-whisper-armed-pill__sep">,
                </span>{{/if}}<span
                class="mod-whisper-armed-pill__user"
              >@{{name}}</span>
            {{/each}}
            {{#each this.groupNames as |name index|}}
              {{#if (this.needsSep index)}}<span
                  class="mod-whisper-armed-pill__sep"
                >, </span>{{/if}}<span
                class="mod-whisper-armed-pill__group"
              >{{name}}</span>
            {{/each}}
            {{#each this.badges as |badge index|}}
              {{#if (this.needsBadgeSep index)}}<span
                  class="mod-whisper-armed-pill__sep"
                >, </span>{{/if}}<span
                class="mod-whisper-armed-pill__badge"
              >{{badge.name}}</span>
            {{/each}}
          </span>
        {{/if}}
        <DButton
          class="btn-flat mod-whisper-armed-pill__close"
          @action={{this.clearArmed}}
          @icon="xmark"
          @title="discourse_mod_categories.whisper.clear_armed"
        />
      </div>
    {{/if}}
  </template>
}
