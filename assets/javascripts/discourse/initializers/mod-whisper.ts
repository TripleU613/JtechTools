import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import type Toolbar from "discourse/lib/composer/toolbar";
import { withPluginApi } from "discourse/lib/plugin-api";
import type Composer from "discourse/models/composer";
import type User from "discourse/models/user";
import type ModalService from "discourse/services/modal";
import type SiteSettings from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";
import ModWhisperTargetModal from "../components/mod-whisper-target-modal.gts";
import {
  clearPendingWhisperEdit,
  takePendingWhisperEdit,
} from "../lib/mod-whisper-pending.ts";
import {
  computeReplyAudience,
  type WhisperComposerFields,
  type WhisperPostFields,
} from "../lib/mod-whisper-reply-audience.ts";

// Inline eye SVG so no icon needs registering.
const EYE_PATH =
  "M12 5c-7 0-10 7-10 7s3 7 10 7 10-7 10-7-3-7-10-7zm0 11a4 4 0 110-8 4 4 0 010 8z";

interface WhisperSiteSettings {
  mod_whisper_enabled?: boolean;
}

type WhisperPost = WhisperPostFields & {
  id: number;
  user_id?: number;
  username?: string;
  avatar_template?: string;
  set?: (key: string, value: unknown) => unknown;
};

type WhisperComposer = Composer &
  WhisperComposerFields & { post?: WhisperPost | null };

interface ComposerServiceWithModel {
  model?: WhisperComposer | null;
}

interface WhisperStateResponse {
  mod_is_whisper: boolean;
  mod_whisper_target_user_ids?: number[];
  mod_whisper_target_group_ids?: number[];
  mod_whisper_target_badge_ids?: number[];
}

interface CookedElementHelper {
  getModel?: () => WhisperPost | null;
  model?: WhisperPost | null;
}

export default {
  name: "discourse-mod-whisper",

  initialize() {
    withPluginApi((api) => {
      const siteSettings: (SiteSettings & WhisperSiteSettings) | undefined =
        api.container.lookup("service:site-settings");
      // Switching whispers off only stops NEW ones: existing whispers stay
      // private on the server, so they keep their banner here (and replies to
      // them stay whispers). Only the tools for creating whispers go away.
      const whispersEnabled = !!siteSettings?.mod_whisper_enabled;

      const currentUser: (User & { id: number }) | null = api.getCurrentUser();

      // Discourse's PostsController#update drops whisper params (the
      // plugin's `add_permitted_post_create_param` whitelist is
      // create-only), so editing a post and changing the whisper state in
      // the modal saves the raw but the whisper state stays whatever it
      // was. The whisper-target modal records the intended state in a
      // module-level pending store at confirm/clear time (edit flow only);
      // flush it with a PUT to the dedicated update_post_whisper endpoint
      // once `composer:saved` confirms the edit save succeeded. Non-staff
      // users never populate the store — the modal isn't opened for them —
      // and the server endpoint 403s defensively even if they did.
      // (An app event, not api.modifyClass("model:composer", { save }) —
      // overriding model methods that way is deprecated,
      // id:discourse.modify-class-model.)
      api.onAppEvent("composer:saved", () => {
        const pendingEdit = takePendingWhisperEdit();
        if (!whispersEnabled || !pendingEdit || !api.getCurrentUser()?.staff) {
          return;
        }

        // Grab the post reference now, while the composer model is still
        // live (the event fires before the composer closes) — the ajax
        // callback below runs after teardown.
        const composerService: ComposerServiceWithModel | undefined =
          api.container.lookup("service:composer");
        const modelPost = composerService?.model?.post;
        const post =
          modelPost?.id === pendingEdit.postId ? modelPost : undefined;

        ajax(`/discourse-mod-categories/post/${pendingEdit.postId}/whisper`, {
          type: "PUT",
          data: pendingEdit.state,
        })
          .then((res: WhisperStateResponse | null) => {
            // Push the new state onto the post so the cooked-element
            // decorator and the post serializer's mod_is_whisper read the
            // same source as the response. Best-effort — the server state
            // is already committed either way.
            if (post?.set) {
              post.set("mod_is_whisper", res?.mod_is_whisper);
              post.set(
                "mod_whisper_target_user_ids",
                res?.mod_whisper_target_user_ids || []
              );
              post.set(
                "mod_whisper_target_group_ids",
                res?.mod_whisper_target_group_ids || []
              );
              post.set(
                "mod_whisper_target_badge_ids",
                res?.mod_whisper_target_badge_ids || []
              );
            }
          })
          .catch(popupAjaxError);
      });

      api.onToolbarCreate((toolbar: Toolbar) => {
        // Whisper-arming is staff-only. Non-staff users replying to an
        // existing whisper post still get their reply auto-armed as a
        // staff-only whisper by the `composer:opened` handler below, so
        // they don't lose the ability to whisper-back — they just don't
        // get a manual UI toggle. Hiding the toolbar button entirely
        // avoids the confusing "eye button that does nothing for me"
        // state that non-staff non-participants used to see.
        if (!whispersEnabled || !currentUser?.staff) {
          return;
        }
        toolbar.addButton({
          id: "mod-whisper-target",
          className: "mod-whisper-target",
          group: "extras",
          icon: "far-eye",
          title: "discourse_mod_categories.whisper.toolbar_title",
          perform: () => {
            const composerService: ComposerServiceWithModel | undefined =
              api.container.lookup("service:composer");
            const model = composerService?.model;
            if (!model) {
              return;
            }
            const modal: ModalService | undefined =
              api.container.lookup("service:modal");
            modal?.show(ModWhisperTargetModal, {
              model: { composer: model },
            });
          },
        });
      });

      api.serializeOnCreate(
        "mod_whisper_target_user_ids",
        "modWhisperTargetUserIds"
      );

      api.serializeOnCreate(
        "mod_whisper_target_group_ids",
        "modWhisperTargetGroupIds"
      );

      api.serializeOnCreate(
        "mod_whisper_target_badge_ids",
        "modWhisperTargetBadgeIds"
      );

      // A boolean armed flag survives form-encoding even when the target id
      // array is empty (a staff-only whisper, or a non-staff whisper-back).
      // It is the server's single signal that a whisper is intended.
      api.serializeOnCreate("mod_whisper", "modWhisperArmed");

      // `addTrackedPostProperties` is the modern replacement for the
      // deprecated `includePostAttributes` — it surfaces the serializer
      // attributes on the post model, which the cooked-element decorator
      // below relies on.
      if (api.addTrackedPostProperties) {
        api.addTrackedPostProperties(
          "mod_is_whisper",
          "mod_whisper_target_user_ids",
          "mod_whisper_targets",
          "mod_whisper_target_group_ids",
          "mod_whisper_target_groups",
          "mod_whisper_target_badge_ids",
          "mod_whisper_target_badges",
          "mod_whisper_is_staff_only",
          "mod_whisper_author_is_staff",
          "mod_whisper_admins_only"
        );
      } else {
        api.includePostAttributes(
          "mod_is_whisper",
          "mod_whisper_target_user_ids",
          "mod_whisper_targets",
          "mod_whisper_target_group_ids",
          "mod_whisper_target_groups",
          "mod_whisper_target_badge_ids",
          "mod_whisper_target_badges",
          "mod_whisper_is_staff_only",
          "mod_whisper_author_is_staff",
          "mod_whisper_admins_only"
        );
      }

      // Held in a variable: core's declared options type omits `id`.
      const decoratorOpts = {
        id: "discourse-mod-whisper-decorator",
        onlyStream: true,
      };
      api.decorateCookedElement(
        (cookedEl: HTMLElement, helper: CookedElementHelper | undefined) => {
          const post = helper?.getModel?.() || helper?.model;

          // Strip prior whisper styling/banner whenever the post is no
          // longer a whisper — covers the convert-to-public action and any
          // future flow that disarms an already-rendered whisper. Without
          // this, the banner + tinted border survive a re-decoration even
          // after `mod_is_whisper` flips to false.
          if (!post?.mod_is_whisper) {
            if (cookedEl.classList.contains("mod-whisper")) {
              cookedEl.classList.remove(
                "mod-whisper",
                "mod-whisper--staff",
                "mod-whisper--user"
              );
            }
            const existingBanner = cookedEl.querySelector(
              ":scope > .mod-whisper-banner"
            );
            if (existingBanner) {
              existingBanner.remove();
            }
            return;
          }

          const targets = Array.isArray(post.mod_whisper_targets)
            ? post.mod_whisper_targets
            : [];
          const targetGroups = Array.isArray(post.mod_whisper_target_groups)
            ? post.mod_whisper_target_groups
            : [];
          const targetBadges = Array.isArray(post.mod_whisper_target_badges)
            ? post.mod_whisper_target_badges
            : [];
          const staffOnly =
            !targets.length && !targetGroups.length && !targetBadges.length;

          // Mark the cooked element itself — a marker on the post <article>
          // does not survive Glimmer post-stream reconciliation. SCSS tints
          // and borders it via these classes.
          cookedEl.classList.add("mod-whisper");
          cookedEl.classList.remove("mod-whisper--staff", "mod-whisper--user");
          cookedEl.classList.add(
            staffOnly ? "mod-whisper--user" : "mod-whisper--staff"
          );

          // Insert the banner as the FIRST CHILD of the cooked element — NOT
          // a sibling. The Glimmer post stream owns the elements around
          // `.cooked`; a foreign sibling gets reconciled away. A child of
          // `.cooked` is re-decorated whenever the cooked HTML re-renders.
          if (cookedEl.querySelector(":scope > .mod-whisper-banner")) {
            return;
          }

          const banner = document.createElement("div");
          banner.className = "mod-whisper-banner";

          const svgNS = "http://www.w3.org/2000/svg";
          const icon = document.createElementNS(svgNS, "svg");
          icon.setAttribute("viewBox", "0 0 24 24");
          icon.setAttribute("width", "14");
          icon.setAttribute("height", "14");
          icon.setAttribute("aria-hidden", "true");
          icon.classList.add("mod-whisper-eye");
          const path = document.createElementNS(svgNS, "path");
          path.setAttribute("fill", "currentColor");
          path.setAttribute("d", EYE_PATH);
          icon.appendChild(path);
          banner.appendChild(icon);

          const label = document.createElement("span");
          label.className = "mod-whisper-banner__label";

          if (staffOnly) {
            label.textContent = ` ${i18n(
              post.mod_whisper_admins_only
                ? "discourse_mod_categories.whisper.banner_to_admins"
                : "discourse_mod_categories.whisper.banner_to_staff"
            )}`;
            banner.appendChild(label);
          } else {
            label.textContent = ` ${i18n(
              "discourse_mod_categories.whisper.banner_to"
            )} `;
            banner.appendChild(label);

            let entryIndex = 0;
            const addSep = () => {
              if (entryIndex > 0) {
                const sep = document.createElement("span");
                sep.className = "mod-whisper-banner__sep";
                sep.textContent = ", ";
                banner.appendChild(sep);
              }
              entryIndex++;
            };

            targets.forEach((t) => {
              addSep();
              const link = document.createElement("a");
              link.className = "mod-whisper-banner__user";
              link.href = `/u/${t.username}`;
              link.textContent = `@${t.username}`;
              banner.appendChild(link);
            });

            targetGroups.forEach((g) => {
              addSep();
              const link = document.createElement("a");
              link.className = "mod-whisper-banner__group";
              link.href = `/g/${g.name}`;
              // "@" as a mention of the group, like the people beside it
              link.textContent = `@${g.name}`;
              banner.appendChild(link);
            });

            targetBadges.forEach((b) => {
              addSep();
              const link = document.createElement("a");
              link.className = "mod-whisper-banner__badge";
              link.href = `/badges/${b.id}`;
              link.textContent = b.name;
              banner.appendChild(link);
            });
          }

          cookedEl.insertBefore(banner, cookedEl.firstChild);
        },
        decoratorOpts
      );

      // Auto-arm a whisper-back when replying to a whisper, for any user who
      // is part of that whisper's audience. This covers the default reply
      // flow; quote-reply behaviour is intentionally unchanged and not
      // special-cased here.
      api.onAppEvent("composer:opened", () => {
        // A pending whisper edit from a cancelled (never-saved) edit must
        // not leak into whatever save happens next.
        clearPendingWhisperEdit();

        const composerService: ComposerServiceWithModel | undefined =
          api.container.lookup("service:composer");
        const model = composerService?.model;
        if (!model || !currentUser) {
          return;
        }
        const post = model.post;
        if (!post?.mod_is_whisper) {
          return;
        }

        if (currentUser.staff) {
          // Carry forward the original whisper's group AND badge targets so
          // a staff reply stays visible to the same audience.
          const replyGroups = Array.isArray(post.mod_whisper_target_groups)
            ? post.mod_whisper_target_groups
            : [];
          const replyBadges = Array.isArray(post.mod_whisper_target_badges)
            ? post.mod_whisper_target_badges
            : [];
          model.set("modWhisperArmed", true);
          model.set(
            "modWhisperTargetGroupIds",
            replyGroups.map((g) => g.id)
          );
          model.set(
            "modWhisperTargetGroupNames",
            replyGroups.map((g) => g.name)
          );
          model.set("modWhisperTargetGroups", replyGroups);
          model.set(
            "modWhisperTargetBadgeIds",
            replyBadges.map((b) => b.id)
          );
          model.set("modWhisperTargetBadges", replyBadges);

          const replyAudience = computeReplyAudience(post, currentUser.id);
          if (replyAudience.length) {
            model.set(
              "modWhisperTargetUserIds",
              replyAudience.map((u) => u.id)
            );
            model.set(
              "modWhisperTargetUsernames",
              replyAudience.map((u) => u.username)
            );
            model.set("modWhisperTargets", replyAudience);
          } else {
            model.set("modWhisperTargetUserIds", []);
            model.set("modWhisperTargetUsernames", []);
            model.set("modWhisperTargets", []);
          }
        } else {
          // Non-staff replying to a whisper they can see — force staff-only.
          model.set("modWhisperArmed", true);
          model.set("modWhisperTargetUserIds", []);
          model.set("modWhisperTargetUsernames", []);
          model.set("modWhisperTargets", []);
          model.set("modWhisperTargetGroupIds", []);
          model.set("modWhisperTargetGroupNames", []);
          model.set("modWhisperTargetGroups", []);
          model.set("modWhisperTargetBadgeIds", []);
          model.set("modWhisperTargetBadges", []);
        }
      });
    });
  },
};
