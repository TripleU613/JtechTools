import { next } from "@ember/runloop";
import type DialogService from "discourse/dialog-holder/services/dialog";
import { withPluginApi } from "discourse/lib/plugin-api";
import type Post from "discourse/models/post";
import { i18n } from "discourse-i18n";
import ListingFormatReqpmButton from "../components/listing-format-reqpm-button.gts";
import ListingFormatStatus from "../components/listing-format-status.gts";
import { buildListingCard } from "../lib/listing-card.ts";
import {
  assemble,
  type ListingComposer,
  listingSetup,
  type ListingTopicFields,
  missingDetails,
  missingValues,
} from "../lib/listing-format.ts";
import type ReqpmService from "../services/reqpm.ts";

interface PostMenuDag {
  add(key: string, value: unknown, position?: { before?: string }): void;
  delete(key: string): void;
}

interface PostMenuContext {
  post: Post & {
    post_number: number;
    user_id: number;
    topic?: ListingTopicFields | null;
  };
  buttonKeys: Record<string, string>;
}

interface ComposerServiceWithModel {
  model?: ListingComposer | null;
}

// Listing topics (see sub_plugins/listing_format.rb): each listing gets the
// seller's REQ-PM button and loses its Reply button, and replying opens a
// form with a fixed label per section above the editor.
export default {
  name: "jtech-listing-format",

  initialize() {
    withPluginApi((api) => {
      const currentUser = api.getCurrentUser();

      api.registerValueTransformer(
        "post-menu-buttons",
        ({
          value: dag,
          context: { post, buttonKeys },
        }: {
          value: PostMenuDag;
          context: PostMenuContext;
        }) => {
          const topic = post.topic;
          if (!topic?.listing_format_topic) {
            return;
          }
          // Only for people who have to post listings, who add one with
          // Create listing instead; staff keep Reply to answer someone.
          if (topic.listing_format_fields?.length) {
            dag.delete(buttonKeys.REPLY);
          }
          if (post.post_number === 1) {
            return;
          }
          const reqpm = api.container.lookup("service:reqpm") as
            | ReqpmService
            | undefined;
          if (
            reqpm?.available &&
            post.user_id > 0 &&
            post.user_id !== currentUser?.id
          ) {
            dag.add("listing-format-reqpm", ListingFormatReqpmButton, {
              before: buttonKeys.SHOW_MORE,
            });
          }
        }
      );

      api.decorateCookedElement(
        (
          element: HTMLElement,
          helper:
            | {
                getModel?: () => PostMenuContext["post"] | null;
                renderGlimmer?: (
                  element: HTMLElement,
                  component: unknown,
                  data: unknown
                ) => void;
              }
            | undefined
        ) => {
          const post = helper?.getModel?.();
          const card = post?.topic?.listing_format_card;
          if (!card || post.post_number === 1) {
            return;
          }
          // Only a post that is a listing gets the sold mark.
          if (!buildListingCard(element, card)) {
            return;
          }
          const cardElement =
            element.querySelector<HTMLElement>(".listing-card");
          if (
            cardElement &&
            !cardElement.querySelector(".listing-card__status")
          ) {
            const holder = document.createElement("div");
            holder.className = "listing-card__status";
            cardElement.appendChild(holder);
            helper?.renderGlimmer?.(holder, ListingFormatStatus, { post });
          }
        },
        { onlyStream: true }
      );

      const composerModel = (): ListingComposer | null | undefined =>
        (
          api.container.lookup("service:composer") as
            | ComposerServiceWithModel
            | undefined
        )?.model;

      api.onAppEvent("composer:opened", () => {
        const model = composerModel();
        if (!model || listingSetup(model)) {
          return;
        }
        const topic = model.topic;
        const fields = topic?.listing_format_fields;
        if (model.action !== "reply" || !fields?.length) {
          return;
        }
        model.set("listingValues", {});
        model.set("listingPicked", {});
        model.set("listingBody", null);
        model.set("listing", {
          fields,
          choices: topic?.listing_format_choices ?? {},
          editorField: topic?.listing_format_editor_field ?? null,
          optional: topic?.listing_format_optional_fields ?? [],
        });
      });

      // Core runs this just before saving, so the form's lines go to the
      // top of the post here. If the save fails, the editor gets its own
      // text back, so a second try doesn't repeat the lines.
      api.registerValueTransformer(
        "composer-service-cannot-submit-post",
        ({
          value,
          context: { model },
        }: {
          value: boolean;
          context: { model?: ListingComposer | null };
        }) => {
          if (!model || !listingSetup(model) || model.listingBody != null) {
            return value;
          }
          const missing = missingValues(model);
          const details = (listingSetup(model)?.fields ?? []).flatMap((field) =>
            missingDetails(model, field).map((option) =>
              i18n("listing_format.composer.missing_details", {
                option,
                field,
              })
            )
          );
          if (missing.length || details.length) {
            const messages = missing.length
              ? [
                  i18n("listing_format.composer.missing", {
                    fields: missing.join(", "),
                  }),
                  ...details,
                ]
              : details;
            (api.container.lookup("service:dialog") as DialogService).alert(
              messages.join(" ")
            );
            // Returning true also makes core check the editor and, when
            // it's empty (no pictures), say the post can't be empty. The
            // form is what's missing, so take that back.
            next(() =>
              (
                api.container.lookup("service:composer") as {
                  set: (key: string, value: unknown) => void;
                }
              ).set("lastValidatedAt", null)
            );
            return true;
          }
          model.set("listingBody", model.reply ?? "");
          model.set("reply", assemble(model));
          if (model.cantSubmitPost) {
            model.set("reply", model.listingBody);
            model.set("listingBody", null);
            return true;
          }
          return false;
        }
      );

      api.addComposerSaveErrorCallback(() => {
        const model = composerModel();
        if (model?.listingBody != null) {
          model.set("reply", model.listingBody);
          model.set("listingBody", null);
        }
        // Not handled: core still shows the server's reason.
        return false;
      });
    });
  },
};
