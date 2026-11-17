# frozen_string_literal: true

require "rails_helper"

# When a whisper post is created, the live MessageBus broadcast that drives
# the sidebar / category unread counter must reach only the whisper's
# audience — staff, the post author, the explicit user/group/badge targets,
# and the topic's cumulative whisper participants. A stranger subscribed to
# the topic's TopicUser row must not get the live "new post" bump (nor does
# their persisted state bump, since `on(:post_created)` rolls back
# Topic#highest_post_number — but the live broadcast was the in-session
# bypass that lit the sidebar between page reloads).
#
# The filter is wired via the `:topic_tracking_state_publish_unread_scope`
# modifier — Discourse hands us the TopicUser AR scope and the post and we
# narrow `user_id IN (audience_ids)` when the post carries the whisper
# custom field.
RSpec.describe "Whisper tracking-state broadcast" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:author, :user)
  fab!(:target, :user)
  fab!(:participant, :user)
  fab!(:stranger, :user)
  fab!(:group_member, :user)
  fab!(:whisper_group) { Fabricate(:group, name: "broadcast_squad") }
  fab!(:topic)
  fab!(:op) { Fabricate(:post, topic: topic, user: author) }
  fab!(:whisper_post) { Fabricate(:post, topic: topic, user: moderator) }

  let(:targets_field) { DiscourseModCategories::POST_WHISPER_TARGETS_FIELD }
  let(:groups_field) { DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD }
  let(:participants_field) { DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.mod_whisper_enabled = true

    Group.refresh_automatic_groups!
    whisper_group.add(group_member)

    # Every fab!'d user gets a TopicUser row so the unfiltered scope would
    # broadcast to ALL of them — the filter under test is what trims the
    # set down to the whisper audience.
    [admin, moderator, author, target, participant, stranger, group_member].each do |u|
      ::TopicUser.create!(
        user_id: u.id,
        topic_id: topic.id,
        notification_level: ::TopicUser.notification_levels[:tracking],
      )
    end
  end

  def filtered_user_ids(post)
    scope = ::TopicUser.where(topic_id: post.topic_id)
    ::DiscoursePluginRegistry.apply_modifier(
      :topic_tracking_state_publish_unread_scope,
      scope,
      post,
    ).pluck(:user_id)
  end

  it "leaves the scope alone for a non-whisper post" do
    expect(filtered_user_ids(op)).to include(stranger.id, target.id, participant.id, admin.id)
  end

  context "with a user-targeted whisper" do
    before do
      whisper_post.custom_fields[targets_field] = [target.id]
      whisper_post.save_custom_fields(true)
      topic.custom_fields[participants_field] = [target.id, participant.id]
      topic.save_custom_fields(true)
      whisper_post.reload
    end

    it "drops the stranger from the broadcast" do
      expect(filtered_user_ids(whisper_post)).not_to include(stranger.id)
    end

    it "keeps the explicit user target in the broadcast" do
      expect(filtered_user_ids(whisper_post)).to include(target.id)
    end

    it "drops a topic participant the whisper doesn't name" do
      expect(filtered_user_ids(whisper_post)).not_to include(participant.id)
    end

    it "keeps staff in the broadcast" do
      expect(filtered_user_ids(whisper_post)).to include(admin.id, moderator.id)
    end

    it "keeps the post author in the broadcast" do
      expect(filtered_user_ids(whisper_post)).to include(moderator.id)
    end
  end

  context "with a group-targeted whisper" do
    before do
      whisper_post.custom_fields[targets_field] = []
      whisper_post.custom_fields[groups_field] = [whisper_group.id]
      whisper_post.save_custom_fields(true)
      whisper_post.reload
    end

    it "keeps members of the target group in the broadcast" do
      expect(filtered_user_ids(whisper_post)).to include(group_member.id)
    end

    it "drops a non-member in the broadcast" do
      expect(filtered_user_ids(whisper_post)).not_to include(stranger.id)
    end
  end

  it "still narrows the broadcast when mod_whisper_enabled is off" do
    whisper_post.custom_fields[targets_field] = [target.id]
    whisper_post.save_custom_fields(true)
    whisper_post.reload

    SiteSetting.mod_whisper_enabled = false
    expect(filtered_user_ids(whisper_post)).not_to include(stranger.id)
    expect(filtered_user_ids(whisper_post)).to include(target.id)
  end
end
