# frozen_string_literal: true

require "rails_helper"

# Core's tracking state gives every whisperer highest_staff_post_number, so a
# whisperer who can't open a trailing whisper (here a moderator and an
# admin's whisper) saw the topic as unread after reading all of it.
RSpec.describe "Whispers a whisperer can't see" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:other_moderator, :moderator)
  fab!(:author, :user)
  fab!(:target, :user)
  fab!(:topic)
  fab!(:op) { Fabricate(:post, topic: topic, user: author) }
  fab!(:reply) { Fabricate(:post, topic: topic, user: author) }

  let(:targets_field) { DiscourseModCategories::POST_WHISPER_TARGETS_FIELD }
  let(:armed_param) { DiscourseModCategories::POST_WHISPER_ARMED_PARAM }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.mod_whisper_enabled = true
    SiteSetting.whispers_allowed_groups = Group::AUTO_GROUPS[:staff].to_s
    SiteSetting.min_post_length = 5
    SiteSetting.body_min_entropy = 1
    SiteSetting.auto_silence_fast_typers_on_first_post = false
    Group.refresh_automatic_groups!
  end

  def whisper_from(user)
    sign_in(user)
    post "/posts.json",
         params: {
           :topic_id => topic.id,
           :raw => "A whisper body long enough to be valid.",
           armed_param => true,
           targets_field => [target.id],
         }
    expect(response.status).to eq(200)
    Post.find(response.parsed_body["id"])
  end

  def read_up_to(user, post_number)
    TopicUser.change(
      user.id,
      topic.id,
      notification_level: TopicUser.notification_levels[:tracking],
      last_read_post_number: post_number,
    )
  end

  def send_timings(user, post_numbers)
    sign_in(user)
    post "/topics/timings.json",
         params: {
           topic_id: topic.id,
           topic_time: 1000,
           timings: post_numbers.to_h { |n| [n, 1000] },
         }
    expect(response.status).to eq(200)
  end

  def unread_topic_ids(user)
    TopicTrackingState.report(user).map(&:topic_id)
  end

  it "counts the topic as read once a moderator reads every post they can see" do
    whisper = whisper_from(admin)
    read_up_to(moderator, op.post_number)

    send_timings(moderator, [reply.post_number])

    expect(TopicUser.get(topic, moderator).last_read_post_number).to eq(whisper.post_number)
    expect(unread_topic_ids(moderator)).not_to include(topic.id)
  end

  it "keeps a caught-up moderator caught up when an admin whispers" do
    read_up_to(moderator, reply.post_number)

    whisper = whisper_from(admin)

    expect(TopicUser.get(topic, moderator).last_read_post_number).to eq(whisper.post_number)
    expect(unread_topic_ids(moderator)).not_to include(topic.id)
  end

  it "leaves a moderator who hasn't read the public posts yet alone" do
    read_up_to(moderator, op.post_number)

    whisper_from(admin)
    send_timings(moderator, [op.post_number])

    expect(TopicUser.get(topic, moderator).last_read_post_number).to eq(op.post_number)
  end

  it "still shows a whisper as unread to a moderator who can see it" do
    read_up_to(other_moderator, reply.post_number)

    whisper_from(moderator)
    send_timings(other_moderator, [reply.post_number])

    expect(TopicUser.get(topic, other_moderator).last_read_post_number).to eq(reply.post_number)
    expect(unread_topic_ids(other_moderator)).to include(topic.id)
  end
end
