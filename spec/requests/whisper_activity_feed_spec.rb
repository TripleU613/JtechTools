# frozen_string_literal: true

require "rails_helper"

# Verifies that whisper posts are filtered out of `/user_actions.json`
# (the feed behind /u/{user}/activity) for viewers who are not in the
# whisper audience. The wrapping module prepended onto UserAction.stream
# delegates to `DiscourseModCategories::UserActionWhisperFilter`, so the
# stream-level test below also exercises the filter end-to-end.
RSpec.describe "Whisper activity feed" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:author, :user)
  fab!(:target, :user)
  fab!(:participant, :user)
  fab!(:stranger, :user)
  fab!(:topic)
  fab!(:op) { Fabricate(:post, topic: topic, user: author) }
  fab!(:regular_reply) { Fabricate(:post, topic: topic, user: moderator) }
  fab!(:whisper_post) { Fabricate(:post, topic: topic, user: moderator) }

  let(:targets_field) { DiscourseModCategories::POST_WHISPER_TARGETS_FIELD }
  let(:participants_field) { DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.mod_whisper_enabled = true

    # Make the moderator's reply post a whisper to `target` + `participant`.
    whisper_post.custom_fields[targets_field] = [target.id]
    whisper_post.save_custom_fields(true)
    topic.custom_fields[participants_field] = [target.id, participant.id]
    topic.save_custom_fields(true)

    # Fabricate the two UserAction rows the moderator's profile would carry —
    # one for the public reply, one for the whisper. The activity feed query
    # joins user_actions to posts/topics, so both rows need to land on the
    # moderator's profile.
    [regular_reply, whisper_post].each do |post|
      ::UserAction.log_action!(
        action_type: ::UserAction::REPLY,
        user_id: moderator.id,
        acting_user_id: moderator.id,
        target_topic_id: topic.id,
        target_post_id: post.id,
      )
    end
  end

  def activity_post_ids_for(viewer)
    sign_in(viewer)
    get "/user_actions.json", params: { username: moderator.username, offset: 0 }
    expect(response.status).to eq(200)
    rows = response.parsed_body["user_actions"] || []
    rows.map { |r| r["post_id"] }.compact
  end

  it "hides the whisper from a stranger's view of the moderator's activity" do
    ids = activity_post_ids_for(stranger)
    expect(ids).to include(regular_reply.id)
    expect(ids).not_to include(whisper_post.id)
  end

  it "shows the whisper to staff (always in audience)" do
    ids = activity_post_ids_for(admin)
    expect(ids).to include(regular_reply.id, whisper_post.id)
  end

  it "shows the whisper to an explicit user target" do
    ids = activity_post_ids_for(target)
    expect(ids).to include(regular_reply.id, whisper_post.id)
  end

  it "hides the whisper from a topic participant it doesn't name" do
    ids = activity_post_ids_for(participant)
    expect(ids).to include(regular_reply.id)
    expect(ids).not_to include(whisper_post.id)
  end

  it "still hides the whisper when mod_whisper_enabled is off" do
    SiteSetting.mod_whisper_enabled = false
    ids = activity_post_ids_for(stranger)
    expect(ids).to include(regular_reply.id)
    expect(ids).not_to include(whisper_post.id)
  end

  describe "UserActionWhisperFilter.apply" do
    let(:rows) do
      [
        Struct.new(:post_id).new(regular_reply.id),
        Struct.new(:post_id).new(whisper_post.id),
        Struct.new(:post_id).new(nil),
      ]
    end

    it "drops the whisper row for a stranger" do
      filtered = DiscourseModCategories::UserActionWhisperFilter.apply(rows, stranger)
      ids = filtered.map(&:post_id)
      expect(ids).to contain_exactly(regular_reply.id, nil)
    end

    it "keeps every row for staff" do
      filtered = DiscourseModCategories::UserActionWhisperFilter.apply(rows, admin)
      expect(filtered.map(&:post_id)).to eq(rows.map(&:post_id))
    end

    it "keeps every row when the input is empty" do
      expect(DiscourseModCategories::UserActionWhisperFilter.apply([], stranger)).to eq([])
    end

    it "still drops the whisper row when mod_whisper_enabled is off" do
      SiteSetting.mod_whisper_enabled = false
      filtered = DiscourseModCategories::UserActionWhisperFilter.apply(rows, stranger)
      expect(filtered.map(&:post_id)).to contain_exactly(regular_reply.id, nil)
    end

    it "drops the whisper row for an anonymous viewer (nil user)" do
      filtered = DiscourseModCategories::UserActionWhisperFilter.apply(rows, nil)
      ids = filtered.map(&:post_id)
      expect(ids).to contain_exactly(regular_reply.id, nil)
    end

    it "fails closed (drops whisper rows) when the precise filter raises" do
      allow(DiscourseModCategories::Whisper).to receive(:hidden_post_ids).and_raise(
        StandardError.new("boom"),
      )
      filtered = DiscourseModCategories::UserActionWhisperFilter.apply(rows, stranger)
      expect(filtered.map(&:post_id)).to contain_exactly(regular_reply.id, nil)
    end

    it "drops every post row when it can't even tell which rows are whispers" do
      allow(::PostCustomField).to receive(:where).and_raise(StandardError.new("boom"))
      filtered = DiscourseModCategories::UserActionWhisperFilter.apply(rows, stranger)
      expect(filtered.map(&:post_id)).to eq([nil])
    end
  end
end
