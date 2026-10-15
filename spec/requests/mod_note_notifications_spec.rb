# frozen_string_literal: true

require "rails_helper"

# Focused coverage for the moderator-note notification fan-out: when a
# moderator sets a private note or replies to the note thread, every
# *other* staff member gets a high-priority bell notification AND a live
# pop-up alert, carrying the data the frontend renderer needs to show
# clear text and link straight to the note. Regular users and the acting
# moderator are never notified.
RSpec.describe "Moderator-note notifications" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:other_moderator, :moderator)
  fab!(:user)
  fab!(:other_user, :user)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }
  fab!(:first_post) { Fabricate(:post, topic: topic) }

  before do
    SiteSetting.mod_categories_enabled = true
    # The live pop-up alert is only published to staff seen recently
    # (Discourse's `allow_live_notifications?` gate), so mark them present.
    [admin, moderator, other_moderator].each { |u| u.update!(last_seen_at: Time.zone.now) }
  end

  def custom_notifications(target)
    Notification.where(
      user_id: target.id,
      notification_type: Notification.types[:custom],
      topic_id: topic.id,
    )
  end

  def set_note(raw = "Heads up, staff.")
    put "/discourse-mod-categories/topic/#{topic.id}.json", params: { private_note: raw }
  end

  describe "setting a private note" do
    it "notifies every other staff member" do
      sign_in(moderator)

      set_note

      expect(custom_notifications(admin).count).to eq(1)
      expect(custom_notifications(other_moderator).count).to eq(1)
    end

    it "does not notify the moderator who set the note" do
      sign_in(moderator)

      set_note

      expect(custom_notifications(moderator).count).to eq(0)
    end

    it "does not notify regular users" do
      sign_in(moderator)

      set_note

      expect(custom_notifications(user).count).to eq(0)
      expect(custom_notifications(other_user).count).to eq(0)
    end

    it "records the acting moderator as the notification's display username" do
      sign_in(moderator)

      set_note

      data = JSON.parse(custom_notifications(admin).first.data)
      expect(data["display_username"]).to eq(moderator.username)
      expect(data["message"]).to eq("discourse_mod_categories.note_notification")
    end

    it "creates the notification as high priority so it pops up live" do
      sign_in(moderator)

      set_note

      expect(custom_notifications(admin).first.high_priority).to eq(true)
    end

    it "marks the notification data so the frontend renderer recognizes it" do
      sign_in(moderator)

      set_note

      data = JSON.parse(custom_notifications(admin).first.data)
      expect(data["mod_note"]).to eq(true)
      expect(data["topic_title"]).to eq(topic.title)
      expect(data["url"]).to eq(
        "#{topic.relative_url}/#{topic.reload.highest_post_number}#mod-private-note",
      )
    end

    it "publishes a live pop-up alert to every other staff member" do
      sign_in(moderator)

      messages =
        MessageBus
          .track_publish { set_note }
          .select { |m| m.channel.start_with?("/notification-alert/") }

      alerted = messages.map(&:channel)
      expect(alerted).to include("/notification-alert/#{admin.id}")
      expect(alerted).to include("/notification-alert/#{other_moderator.id}")
      expect(alerted).not_to include("/notification-alert/#{moderator.id}")

      payload = messages.first.data
      expect(payload[:post_url]).to eq(
        "#{topic.relative_url}/#{topic.reload.highest_post_number}#mod-private-note",
      )
      expect(payload[:translated_title]).to include(moderator.username)
      expect(payload[:translated_title]).to include(topic.title)
    end

    it "links the notification to the topic's last post" do
      sign_in(moderator)

      set_note

      notification = custom_notifications(admin).first
      expect(notification.topic_id).to eq(topic.id)
      expect(notification.post_number).to eq(topic.reload.highest_post_number)
    end

    # an admin's note is the admins' (spec/requests/notes_admins_only_spec.rb)
    it "notifies the other admins, and no moderators, when an admin sets the note" do
      other_admin = Fabricate(:admin)
      sign_in(admin)

      set_note

      expect(custom_notifications(other_admin).count).to eq(1)
      expect(custom_notifications(moderator).count).to eq(0)
      expect(custom_notifications(other_moderator).count).to eq(0)
      expect(custom_notifications(admin).count).to eq(0)
    end

    it "fans out a fresh notification each time the note is updated" do
      sign_in(moderator)

      set_note("First note.")
      set_note("Updated note.")

      expect(custom_notifications(admin).count).to eq(2)
    end
  end

  describe "replying to a note thread" do
    it "notifies other staff when a reply is added" do
      sign_in(moderator)

      post "/discourse-mod-categories/topic/#{topic.id}/note-reply.json",
           params: {
             raw: "Following up.",
           }

      expect(custom_notifications(admin).count).to eq(1)
      expect(custom_notifications(other_moderator).count).to eq(1)
    end

    it "creates a high-priority notification and a live alert on a reply" do
      sign_in(moderator)

      messages =
        MessageBus.track_publish do
          post "/discourse-mod-categories/topic/#{topic.id}/note-reply.json",
               params: {
                 raw: "Following up.",
               }
        end

      expect(custom_notifications(admin).first.high_priority).to eq(true)
      alerted = messages.map(&:channel).select { |c| c.start_with?("/notification-alert/") }
      expect(alerted).to include("/notification-alert/#{admin.id}")
    end

    it "marks each reply notification as a reply with the excerpt and anchored URL" do
      sign_in(moderator)

      post "/discourse-mod-categories/topic/#{topic.id}/note-reply.json",
           params: {
             raw: "Following up on this thread.",
           }

      data = JSON.parse(custom_notifications(admin).first.data)
      expect(data["mod_note"]).to eq(true)
      expect(data["mod_note_kind"]).to eq("reply")
      expect(data["excerpt"]).to eq("Following up on this thread.")
      expect(data["reply_id"]).to be_present
      expect(data["message"]).to eq("discourse_mod_categories.note_reply_notification")
      expect(data["url"]).to eq(
        "#{topic.relative_url}/#{topic.reload.highest_post_number}#mod-private-note-reply-#{data["reply_id"]}",
      )
    end

    it "creates a distinct notification per reply so they stack in the bell" do
      sign_in(moderator)

      post "/discourse-mod-categories/topic/#{topic.id}/note-reply.json",
           params: {
             raw: "First reply.",
           }
      post "/discourse-mod-categories/topic/#{topic.id}/note-reply.json",
           params: {
             raw: "Second reply.",
           }
      post "/discourse-mod-categories/topic/#{topic.id}/note-reply.json",
           params: {
             raw: "Third reply.",
           }

      rows = custom_notifications(admin).order(:id)
      expect(rows.count).to eq(3)

      excerpts = rows.map { |n| JSON.parse(n.data)["excerpt"] }
      reply_ids = rows.map { |n| JSON.parse(n.data)["reply_id"] }
      expect(excerpts).to eq(["First reply.", "Second reply.", "Third reply."])
      expect(reply_ids.uniq.size).to eq(3)
    end

    it "does not notify the moderator who wrote the reply" do
      sign_in(other_moderator)

      post "/discourse-mod-categories/topic/#{topic.id}/note-reply.json",
           params: {
             raw: "Following up.",
           }

      expect(custom_notifications(other_moderator).count).to eq(0)
    end

    it "does not notify regular users on a reply" do
      sign_in(moderator)

      post "/discourse-mod-categories/topic/#{topic.id}/note-reply.json",
           params: {
             raw: "Following up.",
           }

      expect(custom_notifications(user).count).to eq(0)
    end

    it "does not notify on a rejected blank reply" do
      sign_in(moderator)

      expect {
        post "/discourse-mod-categories/topic/#{topic.id}/note-reply.json", params: { raw: "   " }
      }.not_to change { custom_notifications(admin).count }
    end
  end
end
