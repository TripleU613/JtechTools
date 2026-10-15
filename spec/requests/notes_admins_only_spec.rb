# frozen_string_literal: true

require "rails_helper"

# An admin's note on a topic is the admins', replies and all: a moderator
# doesn't get it in the topic, the notes feed or the alerts, and can't reply
# to it, edit it, delete it or write over it. A moderator's note, with an
# admin's reply in it, stays every staff member's.
RSpec.describe "Admins' notes" do
  fab!(:admin)
  fab!(:other_admin, :admin)
  fab!(:moderator)
  fab!(:topic)
  fab!(:first_post) { Fabricate(:post, topic: topic) }

  let(:base) { "/discourse-mod-categories/topic/#{topic.id}" }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.mod_topic_private_notes_enabled = true
    SiteSetting.mod_notes_feed_enabled = true
    SiteSetting.mod_notify_staff_on_topic_notes = true
  end

  def write_note(user, text)
    sign_in(user)
    put "#{base}.json", params: { private_note: text }
    expect(response.status).to eq(200)
  end

  def topic_json(user)
    sign_in(user)
    get "/t/#{topic.id}.json"
    response.parsed_body
  end

  def note_alerts_for(user)
    DiscourseModCategories::StaffNotifier.mod_notes_for(user.id).where(topic_id: topic.id)
  end

  it "keeps an admin's note from moderators" do
    write_note(admin, "Admins only, please.")

    expect(topic_json(other_admin)["mod_topic_private_note"]).to eq("Admins only, please.")
    expect(topic_json(moderator)).not_to have_key("mod_topic_private_note")
    expect(topic_json(moderator)).not_to have_key("mod_topic_private_note_replies")
    expect(note_alerts_for(other_admin).count).to eq(1)
    expect(note_alerts_for(moderator).count).to eq(0)

    sign_in(moderator)
    get "/discourse-mod-categories/notes-feed.json"
    expect(response.parsed_body.to_s).not_to include("Admins only")
  end

  it "doesn't let a moderator reply to, overwrite or delete an admin's note" do
    write_note(admin, "Admins only, please.")
    sign_in(moderator)

    post "#{base}/note-reply.json", params: { raw: "Seen it" }
    expect(response.status).to eq(404)

    put "#{base}.json", params: { private_note: "Mine now" }
    expect(response.status).to eq(404)

    delete "#{base}/note.json"
    expect(response.status).to eq(404)

    expect(topic.reload.custom_fields[DiscourseModCategories::TOPIC_PRIVATE_NOTE_FIELD]).to eq(
      "Admins only, please.",
    )
  end

  it "leaves a moderator's note, and an admin's reply in it, to every staff member" do
    write_note(moderator, "For all staff.")
    sign_in(admin)
    post "#{base}/note-reply.json", params: { raw: "Agreed." }
    expect(response.status).to eq(200)

    json = topic_json(moderator)
    expect(json["mod_topic_private_note"]).to eq("For all staff.")
    expect(json["mod_topic_private_note_replies"].map { |r| r["raw"] }).to include("Agreed.")
  end
end
