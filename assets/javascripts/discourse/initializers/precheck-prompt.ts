import type Owner from "@ember/owner";
import type DialogService from "discourse/dialog-holder/services/dialog";
import { withPluginApi } from "discourse/lib/plugin-api";
import type ModalService from "discourse/services/modal";
import type SiteSettings from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";
import ModFirstPostChecklist from "../components/mod-first-post-checklist.gts";
import {
  type ChecklistUser,
  composerTopicId,
  firstPostChecklistFor,
  refreshOwedChecklist,
} from "../lib/first-post-checklist.ts";
import { messageToHtml } from "../lib/linkify-message.ts";
import {
  PRECHECK_CONFIRM_KEY,
  PRECHECK_GO_BACK_KEY,
  PRECHECK_TITLE_KEY,
  type PrecheckComposer,
  precheckPromptFor,
  type PrecheckSiteSettings,
  type PrecheckUser,
} from "../lib/precheck-prompt.ts";

// Gates the composer submit, in order:
//   1. the forum-wide first-post checklist a new user must acknowledge;
//   2. the moderator's per-category (new topic) / per-topic (reply) prompt.
// `composerBeforeSave` replaces Composer#beforeSave, so a single handler
// runs both gates; each resolves when it does not apply, and a rejection
// aborts the save and keeps the composer open with content intact.
export default {
  name: "discourse-mod-precheck-prompt",

  initialize(container: Owner) {
    const siteSettings = container.lookup(
      "service:site-settings"
    ) as SiteSettings & PrecheckSiteSettings;
    const currentUser = container.lookup("service:current-user") as
      | (ChecklistUser & PrecheckUser)
      | null;

    // Shows the first-post checklist modal when the current user still
    // owes an acknowledgement; resolves immediately otherwise.
    //
    // The owed checklist is re-fetched from the server first so a version
    // bump made mid-session (no hard refresh) is still gated, and so an
    // already-accepted checklist is not re-shown.
    async function checklistGate(composer: PrecheckComposer): Promise<void> {
      await refreshOwedChecklist(currentUser, composerTopicId(composer));

      const checklist = firstPostChecklistFor(composer, currentUser);
      if (!checklist) {
        return Promise.resolve();
      }

      const modal = container.lookup("service:modal") as ModalService;
      return new Promise<void>((resolve, reject) => {
        modal.show(ModFirstPostChecklist, {
          model: { checklist, onAccept: resolve, onCancel: reject },
        });
      });
    }

    // Shows the moderator's confirmation prompt for this composer save.
    function precheckGate(composer: PrecheckComposer): Promise<void> {
      const message = precheckPromptFor(composer, siteSettings, currentUser);
      if (!message) {
        return Promise.resolve();
      }

      const dialog = container.lookup("service:dialog") as DialogService;
      return new Promise<void>((resolve, reject) => {
        dialog.confirm({
          message: messageToHtml(message),
          title: i18n(PRECHECK_TITLE_KEY),
          confirmButtonLabel: PRECHECK_CONFIRM_KEY,
          cancelButtonLabel: PRECHECK_GO_BACK_KEY,
          didConfirm: resolve,
          didCancel: reject,
        });
      });
    }

    withPluginApi((api) => {
      // `checklistGate` re-fetches `/checklist/owed` before reading the
      // owed checklist, so a checklist version bumped by staff mid-session
      // is gated without the user needing a hard page refresh.
      api.composerBeforeSave(function (this: PrecheckComposer) {
        return checklistGate(this).then(() => precheckGate(this));
      });
    });
  },
};
