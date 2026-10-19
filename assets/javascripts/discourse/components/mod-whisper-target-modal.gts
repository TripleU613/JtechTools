import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import { service } from "@ember/service";
import type { ComponentLike } from "@glint/template";
import UntypedMultiSelect from "select-kit/components/multi-select";
import DButton from "discourse/components/d-button";
import DModal from "discourse/components/d-modal";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import type Composer from "discourse/models/composer";
import EmailGroupUserChooser from "discourse/select-kit/components/email-group-user-chooser";
import type SiteSettings from "discourse/services/site-settings";
import type StoreService from "discourse/services/store";
import { i18n } from "discourse-i18n";
import {
  setPendingWhisperEdit,
  type WhisperStatePayload,
} from "../lib/mod-whisper-pending.ts";
import type {
  WhisperComposerFields,
  WhisperTargetGroup,
  WhisperTargetUser,
} from "../lib/mod-whisper-reply-audience.ts";
import type { BadgeChoice, BadgeRecord } from "./mod-pm-badge-picker.gts";

// Select-kit components are classic components with no Glint signature;
// this gives MultiSelect one so `class` and the args used here type-check.
interface MultiSelectSignature {
  Element: HTMLElement;
  Args: {
    value: number[];
    content: BadgeChoice[];
    nameProperty?: string;
    valueProperty?: string;
    onChange: (ids: (number | string)[] | null) => void;
    options?: { filterPlaceholder?: string };
  };
}
const MultiSelect =
  UntypedMultiSelect as unknown as ComponentLike<MultiSelectSignature>;

export type WhisperTargetComposer = Composer &
  WhisperComposerFields & { post?: { id?: number } | null };

interface WhisperTargetSiteSettings {
  mod_whisper_badge_targeting_enabled: boolean;
}

interface ModWhisperTargetModalSignature {
  Args: {
    model: { composer: WhisperTargetComposer };
    closeModal: () => void;
  };
}

// Staff-facing modal (opened from the composer toolbar eye button) for
// picking the users, groups, AND badges a whisper reply should be visible
// to. Writes the chosen ids/usernames/group ids/group names/badge ids/
// badge names onto the composer model. The user+group chooser returns a
// flat array mixing usernames and group names; `confirm` resolves each
// entry to either a user id or a group id. Badge selection is independent.
export default class ModWhisperTargetModal extends Component<ModWhisperTargetModalSignature> {
  @service declare store: StoreService;
  @service declare siteSettings: SiteSettings & WhisperTargetSiteSettings;

  @tracked selection: string[] = this.#initialSelection();
  @tracked selectedBadgeIds: number[] = this.#initialBadgeIds();
  @tracked badgeChoices: BadgeChoice[] = [];
  @tracked saving = false;

  constructor(owner: Owner, args: ModWhisperTargetModalSignature["Args"]) {
    super(owner, args);
    this.#loadBadges();
  }

  @action
  updateSelection(names: string[]) {
    this.selection = names;
  }

  @action
  updateBadgeSelection(ids: (number | string)[] | null) {
    this.selectedBadgeIds = (ids || []).map((n) => Number(n));
  }

  @action
  async confirm() {
    const composer = this.args.model?.composer;
    if (!composer) {
      this.args.closeModal();
      return;
    }

    const badgeIds = this.selectedBadgeIds.slice();
    const badges = this.badgeChoices.filter((b) => badgeIds.includes(b.id));

    if (!this.selection.length && !badgeIds.length) {
      // An empty selection still ARMS a whisper — a staff-only whisper-back.
      composer.set("modWhisperArmed", true);
      composer.set("modWhisperTargetUserIds", []);
      composer.set("modWhisperTargetUsernames", []);
      composer.set("modWhisperTargets", []);
      composer.set("modWhisperTargetGroupIds", []);
      composer.set("modWhisperTargetGroupNames", []);
      composer.set("modWhisperTargetGroups", []);
      composer.set("modWhisperTargetBadgeIds", []);
      composer.set("modWhisperTargetBadges", []);
      this.#recordPendingEdit(composer, {
        mod_whisper: true,
        mod_whisper_target_user_ids: [],
        mod_whisper_target_group_ids: [],
        mod_whisper_target_badge_ids: [],
      });
      this.args.closeModal();
      return;
    }

    if (!this.selection.length && badgeIds.length) {
      // Badge-only audience — no user or group lookups needed.
      composer.set("modWhisperArmed", true);
      composer.set("modWhisperTargetUserIds", []);
      composer.set("modWhisperTargetUsernames", []);
      composer.set("modWhisperTargets", []);
      composer.set("modWhisperTargetGroupIds", []);
      composer.set("modWhisperTargetGroupNames", []);
      composer.set("modWhisperTargetGroups", []);
      composer.set("modWhisperTargetBadgeIds", badgeIds);
      composer.set("modWhisperTargetBadges", badges);
      this.#recordPendingEdit(composer, {
        mod_whisper: true,
        mod_whisper_target_user_ids: [],
        mod_whisper_target_group_ids: [],
        mod_whisper_target_badge_ids: badgeIds,
      });
      this.args.closeModal();
      return;
    }

    this.saving = true;
    try {
      // Each selected name is EITHER a username OR a group name. Resolve all
      // of them via /groups/<name>.json first; whatever is not a real group
      // is treated as a username and resolved via /u/<name>.json.
      const groupLookups = await Promise.all(
        this.selection.map((name) =>
          ajax(`/groups/${encodeURIComponent(name)}.json`)
            .then((data: { group?: WhisperTargetGroup } | null) => data?.group)
            .catch(() => null)
        )
      );

      const groups: WhisperTargetGroup[] = [];
      const remainingUsernames: string[] = [];
      this.selection.forEach((name, index) => {
        const group = groupLookups[index];
        if (group?.id) {
          groups.push(group);
        } else {
          remainingUsernames.push(name);
        }
      });

      const userLookups = await Promise.all(
        remainingUsernames.map((username) =>
          ajax(`/u/${encodeURIComponent(username)}.json`)
            .then((data: { user?: WhisperTargetUser } | null) => data?.user)
            .catch(() => null)
        )
      );
      const users = userLookups.filter(Boolean);

      composer.set("modWhisperArmed", true);
      composer.set(
        "modWhisperTargetUserIds",
        users.map((u) => u.id)
      );
      composer.set(
        "modWhisperTargetUsernames",
        users.map((u) => u.username)
      );
      composer.set(
        "modWhisperTargets",
        users.map((u) => ({
          id: u.id,
          username: u.username,
          avatar_template: u.avatar_template,
        }))
      );

      composer.set(
        "modWhisperTargetGroupIds",
        groups.map((g) => g.id)
      );
      composer.set(
        "modWhisperTargetGroupNames",
        groups.map((g) => g.name)
      );
      composer.set(
        "modWhisperTargetGroups",
        groups.map((g) => ({ id: g.id, name: g.name }))
      );

      composer.set("modWhisperTargetBadgeIds", badgeIds);
      composer.set("modWhisperTargetBadges", badges);

      this.#recordPendingEdit(composer, {
        mod_whisper: true,
        mod_whisper_target_user_ids: users.map((u) => u.id),
        mod_whisper_target_group_ids: groups.map((g) => g.id),
        mod_whisper_target_badge_ids: badgeIds,
      });
      this.args.closeModal();
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.saving = false;
    }
  }

  @action
  clear() {
    const composer = this.args.model?.composer;
    if (composer) {
      composer.set("modWhisperArmed", false);
      composer.set("modWhisperTargetUserIds", null);
      composer.set("modWhisperTargetUsernames", null);
      composer.set("modWhisperTargets", null);
      composer.set("modWhisperTargetGroupIds", null);
      composer.set("modWhisperTargetGroupNames", null);
      composer.set("modWhisperTargetGroups", null);
      composer.set("modWhisperTargetBadgeIds", null);
      composer.set("modWhisperTargetBadges", null);
      // Disarm is also a whisper-state change — an edit save must
      // propagate the "remove whisper" intent to the server.
      this.#recordPendingEdit(composer, {
        mod_whisper: false,
        mod_whisper_target_user_ids: [],
        mod_whisper_target_group_ids: [],
        mod_whisper_target_badge_ids: [],
      });
    }
    this.args.closeModal();
  }

  #initialSelection(): string[] {
    const composer = this.args.model?.composer;
    const usernames = Array.isArray(composer?.modWhisperTargetUsernames)
      ? composer.modWhisperTargetUsernames
      : [];
    const groupNames = Array.isArray(composer?.modWhisperTargetGroupNames)
      ? composer.modWhisperTargetGroupNames
      : [];
    return [...usernames, ...groupNames];
  }

  #initialBadgeIds(): number[] {
    const composer = this.args.model?.composer;
    const ids = Array.isArray(composer?.modWhisperTargetBadgeIds)
      ? composer.modWhisperTargetBadgeIds
      : [];
    return ids.map((n) => Number(n)).filter((n) => Number.isInteger(n));
  }

  async #loadBadges() {
    try {
      if (!this.siteSettings.mod_whisper_badge_targeting_enabled) {
        this.badgeChoices = [];
        return;
      }
      const list = await this.store.findAll("badge", undefined);
      this.badgeChoices = (list?.content || list || [])
        .filter((b: BadgeRecord | null) => b?.enabled !== false)
        .map((b: BadgeRecord) => ({
          id: b.id,
          name: b.display_name || b.name,
        }));
    } catch {
      this.badgeChoices = [];
    }
  }

  // On an EDIT, changing the whisper state needs a follow-up PUT to the
  // update_post_whisper endpoint after the edit save (core's
  // PostsController#update drops whisper params). Record the intended
  // state now, while the composer model and its post are live; the
  // mod-whisper initializer flushes it on `composer:saved`. Creates need
  // nothing here — their whisper params ride the creation payload via
  // serializeOnCreate.
  #recordPendingEdit(
    composer: WhisperTargetComposer,
    state: WhisperStatePayload
  ) {
    if (composer.editingPost && composer.post?.id) {
      setPendingWhisperEdit({ postId: composer.post.id, state });
    }
  }

  <template>
    <DModal
      class="mod-whisper-target-modal"
      @closeModal={{@closeModal}}
      @title={{i18n "discourse_mod_categories.whisper.modal_title"}}
    >
      <:body>
        <EmailGroupUserChooser
          @onChange={{this.updateSelection}}
          @options={{hash
            maximum=10
            includeGroups=true
            filterPlaceholder="discourse_mod_categories.whisper.search_placeholder"
          }}
          @value={{this.selection}}
        />

        {{#if this.badgeChoices.length}}
          <label class="mod-whisper-target-modal__badge-label">
            {{i18n "discourse_mod_categories.whisper.badge_label"}}
          </label>
          <MultiSelect
            class="mod-whisper-target-modal__badges"
            @content={{this.badgeChoices}}
            @nameProperty="name"
            @onChange={{this.updateBadgeSelection}}
            @options={{hash
              filterPlaceholder="discourse_mod_categories.whisper.badge_search_placeholder"
            }}
            @value={{this.selectedBadgeIds}}
            @valueProperty="id"
          />
        {{/if}}
      </:body>
      <:footer>
        <DButton
          class="btn-primary mod-whisper-confirm"
          @action={{this.confirm}}
          @disabled={{this.saving}}
          @label="discourse_mod_categories.whisper.confirm"
        />
        <DButton
          class="btn-flat"
          @action={{this.clear}}
          @label="discourse_mod_categories.whisper.clear"
        />
      </:footer>
    </DModal>
  </template>
}
