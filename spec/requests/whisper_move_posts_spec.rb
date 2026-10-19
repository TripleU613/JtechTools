# frozen_string_literal: true

require "rails_helper"
require_relative "../../db/migrate/20261019000001_clear_whisper_topic_excerpts"

# Moving posts into a topic bumps it when its last public post is one of
# them. A moved whisper is a regular post, so it must not count: the topic
# would jump up the list, and show the whisper's author as its last poster,
# for everyone outside the whisper's audience.
RSpec.describe "Moving a whisper into another topic" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:author, :user)
  fab!(:target, :user)
  fab!(:other_poster, :user)
  fab!(:topic)
  fab!(:op) { Fabricate(:post, topic: topic, user: author) }
  fab!(:regular_reply) { Fabricate(:post, topic: topic, user: author) }
  fab!(:whisper_post) { Fabricate(:post, topic: topic, user: moderator) }
  fab!(:destination, :topic)
  fab!(:destination_op) { Fabricate(:post, topic: destination, user: other_poster) }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.mod_whisper_enabled = true

    whisper_post.custom_fields[DiscourseModCategories::POST_WHISPER_TARGETS_FIELD] = [target.id]
    whisper_post.save_custom_fields(true)
    DiscourseModCategories::Whisper.refresh_topic_counters(topic)

    regular_reply.update_columns(created_at: 30.minutes.ago)
    whisper_post.update_columns(created_at: 5.minutes.ago)
    # one time for both: the move recomputes last_posted_at from the last
    # public post, so the two have to agree as they do in a real topic
    destination_posted_at = 3.hours.ago
    destination_op.update_columns(created_at: destination_posted_at)
    ::Topic.where(id: destination.id).update_all(
      bumped_at: destination_posted_at,
      last_posted_at: destination_posted_at,
      last_post_user_id: other_poster.id,
    )
    sign_in(admin)
  end

  it "leaves the destination's bump and last poster alone when only a whisper moves" do
    before = destination.reload.slice(:bumped_at, :last_posted_at)

    post "/t/#{topic.id}/move-posts.json",
         params: {
           post_ids: [whisper_post.id],
           destination_topic_id: destination.id,
         }

    expect(response.status).to eq(200)
    expect(whisper_post.reload.topic_id).to eq(destination.id)
    expect(DiscourseModCategories::Whisper.whisper?(whisper_post)).to eq(true)

    destination.reload
    expect(destination.bumped_at).to eq_time(before["bumped_at"])
    expect(destination.last_posted_at).to eq_time(before["last_posted_at"])
    expect(destination.last_post_user_id).to eq(other_poster.id)
  end

  it "still bumps the destination for a public post moved with a whisper after it" do
    freeze_time

    post "/t/#{topic.id}/move-posts.json",
         params: {
           post_ids: [regular_reply.id, whisper_post.id],
           destination_topic_id: destination.id,
         }

    expect(response.status).to eq(200)
    destination.reload
    expect(destination.bumped_at).to eq_time(Time.zone.now)
    expect(destination.last_posted_at).to eq_time(regular_reply.created_at)
    expect(destination.last_post_user_id).to eq(author.id)
  end

  # A topic's title, excerpt and owner are public, so its first post can't be
  # a whisper. Moving one into a new topic, or ahead of an existing topic's
  # first post, would make it one.
  describe "a whisper as a topic's first post" do
    let(:refusal) { I18n.t("discourse_mod_categories.whisper.move_first_post_not_allowed") }

    it "refuses to start a new topic with a whisper" do
      expect {
        post "/t/#{topic.id}/move-posts.json",
             params: {
               post_ids: [whisper_post.id],
               title: "A new topic made from a whisper",
             }
      }.not_to change { Topic.count }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq([refusal])
      expect(whisper_post.reload.topic_id).to eq(topic.id)
    end

    it "refuses to start a new topic with a copy of a whisper" do
      expect {
        post "/t/#{topic.id}/move-posts.json",
             params: {
               post_ids: [whisper_post.id],
               title: "A new topic made from a whisper",
               freeze_original: true,
             }
      }.not_to change { Post.count }

      expect(response.status).to eq(422)
    end

    it "refuses to put a whisper ahead of an existing topic's first post" do
      whisper_post.update_columns(created_at: 4.hours.ago)

      post "/t/#{topic.id}/move-posts.json",
           params: {
             post_ids: [whisper_post.id],
             destination_topic_id: destination.id,
             chronological_order: true,
           }

      expect(response.status).to eq(422)
      expect(destination_op.reload.post_number).to eq(1)
      expect(destination.reload.user_id).not_to eq(moderator.id)
    end

    it "starts a new topic with a public post, and the whisper after it stays private" do
      post "/t/#{topic.id}/move-posts.json",
           params: {
             post_ids: [regular_reply.id, whisper_post.id],
             title: "A new topic made from a reply",
           }

      expect(response.status).to eq(200)
      new_topic = regular_reply.reload.topic
      expect(new_topic.id).not_to eq(topic.id)
      expect(regular_reply.post_number).to eq(1)
      expect(whisper_post.reload.topic_id).to eq(new_topic.id)
      expect(Guardian.new(other_poster).can_see_post?(whisper_post)).to eq(false)
    end
  end

  # One moved to the head of a topic before such moves were refused: the
  # topic took its excerpt and picture from the whisper.
  describe "a topic a whisper already heads" do
    fab!(:upload, :image_upload)
    fab!(:headed_topic, :topic)
    fab!(:headed_whisper) do
      Fabricate(
        :post,
        topic: headed_topic,
        user: moderator,
        raw:
          "Only for you: zebrasecret. <img src=\"#{upload.url}\" width=\"1500\" height=\"2000\">",
      )
    end

    before do
      headed_whisper.custom_fields[DiscourseModCategories::POST_WHISPER_TARGETS_FIELD] = [target.id]
      headed_whisper.save_custom_fields(true)
      headed_topic.update_columns(excerpt: "Only for you: zebrasecret.", image_upload_id: upload.id)
    end

    it "loses the excerpt and picture it took from the whisper" do
      topic.update_columns(excerpt: "A public excerpt.")

      ActiveRecord::Migration.suppress_messages { ClearWhisperTopicExcerpts.new.up }

      expect(headed_topic.reload.excerpt).to be_nil
      expect(headed_topic.image_upload_id).to be_nil
      expect(topic.reload.excerpt).to eq("A public excerpt.")
    end

    it "doesn't take them back from the whisper when it's rebaked" do
      headed_topic.update_columns(excerpt: nil, image_upload_id: nil)

      headed_whisper.rebake!
      CookedPostProcessor.new(headed_whisper.reload).post_process

      expect(headed_topic.reload.excerpt).to be_nil
      expect(headed_topic.image_upload_id).to be_nil
    end
  end
end
