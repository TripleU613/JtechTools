import { settings, themePrefix } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import type AppEvents from "discourse/services/app-events";
import { i18n } from "discourse-i18n";
import JtClosedReplyWarning from "../components/jt-closed-reply-warning.gts";

interface ReplyComposer {
  model?: {
    replyingToTopic?: boolean;
    topic?: ReplyTopic;
    post?: { topic?: ReplyTopic };
  };
}

interface ReplyTopic {
  closed?: boolean;
  archived?: boolean;
  details?: { can_create_post?: boolean };
}

const warned = new WeakSet<object>();

// Replying to a closed or archived topic is only possible for staff and the
// category's moderators, and easy to do without noticing: the composer says
// so, once per reply, with buttons to reopen or unarchive (setting
// closed_reply_warning; it replaces the forum's Admin Warnings component).
export default apiInitializer((api) => {
  if (!settings.closed_reply_warning) {
    return;
  }

  api.registerValueTransformer(
    "composer-message-components",
    ({ value }: { value: Record<string, unknown> }) => {
      value["jt-closed-reply"] = JtClosedReplyWarning;
    }
  );

  api.onAppEvent("composer:opened", () => {
    // the composer service's model isn't in core's types
    const { model } = api.container.lookup(
      "service:composer"
    ) as unknown as ReplyComposer;
    if (!model?.replyingToTopic || warned.has(model)) {
      return;
    }
    const topic = model.topic ?? model.post?.topic;
    if (!topic || (!topic.closed && !topic.archived)) {
      return;
    }
    if (!topic.details?.can_create_post) {
      return;
    }
    warned.add(model);
    (api.container.lookup("service:app-events") as AppEvents).trigger(
      "composer-messages:create",
      {
        templateName: "jt-closed-reply",
        extraClass: "jt-closed-reply-popup",
        topic,
        body: i18n(
          themePrefix(
            topic.archived
              ? "jt.closed_reply.archived"
              : "jt.closed_reply.closed"
          )
        ),
      }
    );
  });
});
