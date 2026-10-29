# frozen_string_literal: true

require "rails_helper"

# Per-user slow mode: the NewPostManager check that turns away a reply or new
# topic that comes too soon after the user's last one, and what it leaves
# alone (personal messages, edits, staff, an expired or switched-off slow mode).
RSpec.describe DiscourseModCategories::UserSlowMode do
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }
  fab!(:op) { Fabricate(:post, topic: topic) }
  fab!(:user) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:other) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:moderator)
  fab!(:admin)

  before { SiteSetting.mod_categories_enabled = true }

  def slow!(target, seconds: 15.minutes.to_i, ends_at: nil)
    target.custom_fields[described_class::SECONDS_FIELD] = seconds
    target.custom_fields[described_class::UNTIL_FIELD] = ends_at&.iso8601
    target.save_custom_fields(true)
  end

  def reply_as(poster, raw: "A reply that is comfortably long enough to be valid.")
    NewPostManager.new(poster, raw: raw, topic_id: topic.id).perform
  end

  def new_topic_as(poster)
    NewPostManager.new(
      poster,
      raw: "The body of a brand new topic, long enough to be valid.",
      title: "A brand new topic title #{SecureRandom.hex(4)}",
      category: category.id,
    ).perform
  end

  def message_as(poster, to:)
    NewPostManager.new(
      poster,
      raw: "A private message that is comfortably long enough.",
      title: "A private message title #{SecureRandom.hex(4)}",
      archetype: Archetype.private_message,
      target_usernames: to.username,
    ).perform
  end

  it "lets the first post through and turns away the next one, saying how long to wait" do
    slow!(user)

    expect(reply_as(user).success?).to eq(true)

    result = reply_as(user, raw: "Another reply that is long enough to be valid here.")
    expect(result.success?).to eq(false)
    expect(result.errors.full_messages.join).to eq(
      I18n.t("discourse_mod_categories.slow_mode.too_soon", time_left: "15 minutes"),
    )
    expect(topic.posts.where(user: user).count).to eq(1)
  end

  it "lets them post again once the interval has passed" do
    slow!(user)
    reply_as(user)

    freeze_time(16.minutes.from_now) do
      expect(reply_as(user, raw: "A later reply that is long enough to be valid.").success?).to eq(
        true,
      )
    end
  end

  it "counts a post made before slow mode was set" do
    Fabricate(:post, topic: topic, user: user, created_at: 5.minutes.ago)
    slow!(user)

    expect(reply_as(user).success?).to eq(false)
  end

  it "limits new topics as well as replies" do
    slow!(user)
    expect(new_topic_as(user).success?).to eq(true)

    expect(reply_as(user).success?).to eq(false)
    expect(new_topic_as(user).success?).to eq(false)
  end

  it "still counts a post that was deleted" do
    slow!(user)
    result = reply_as(user)
    PostDestroyer.new(admin, result.post).destroy

    expect(reply_as(user, raw: "A second try that is long enough to be valid.").success?).to eq(
      false,
    )
  end

  it "doesn't limit personal messages, or count them" do
    SiteSetting.personal_message_enabled_groups = Group::AUTO_GROUPS[:trust_level_0]
    slow!(user)

    expect(message_as(user, to: other).success?).to eq(true)
    expect(message_as(user, to: other).success?).to eq(true)
    expect(reply_as(user).success?).to eq(true)
  end

  it "doesn't limit edits" do
    slow!(user)
    post = reply_as(user).post

    revised = PostRevisor.new(post).revise!(user, raw: "An edited reply that is long enough to be valid.")
    expect(revised).to be_truthy
    expect(post.reload.raw).to start_with("An edited reply")
  end

  it "holds a user back while a post of theirs waits for approval" do
    slow!(user)
    topic.custom_fields["mod_topic_require_reply_approval"] = true
    topic.save_custom_fields(true)

    expect(reply_as(user).action).to eq(:enqueued)

    other_topic = Fabricate(:topic, category: category)
    result =
      NewPostManager.new(
        user,
        raw: "A reply somewhere else that is long enough.",
        topic_id: other_topic.id,
      ).perform
    expect(result.success?).to eq(false)
    expect(result.errors.full_messages.join).to eq(
      I18n.t("discourse_mod_categories.slow_mode.waiting"),
    )
  end

  it "doesn't hold back other users while one is waiting for approval" do
    slow!(user)
    topic.custom_fields["mod_topic_require_reply_approval"] = true
    topic.save_custom_fields(true)
    reply_as(user)

    other_topic = Fabricate(:topic, category: category)
    result =
      NewPostManager.new(other, raw: "A reply from someone else entirely.", topic_id: other_topic.id)
        .perform
    expect(result.success?).to eq(true)
  end

  it "ends by itself when its time runs out" do
    slow!(user, ends_at: 1.hour.from_now)
    reply_as(user)

    freeze_time(2.hours.from_now) do
      expect(reply_as(user, raw: "A reply after slow mode ended, long enough.").success?).to eq(true)
      expect(described_class.state_for(user.reload)).to be_nil
    end
  end

  it "never limits staff" do
    slow!(moderator)

    expect(reply_as(moderator).success?).to eq(true)
    expect(reply_as(moderator, raw: "A second staff reply that is long enough.").success?).to eq(true)
  end

  it "stops limiting while the feature is off, and resumes when it's back on" do
    slow!(user)
    reply_as(user)

    SiteSetting.mod_user_slow_mode_enabled = false
    expect(reply_as(user, raw: "A reply while the feature is switched off.").success?).to eq(true)

    SiteSetting.mod_user_slow_mode_enabled = true
    expect(reply_as(user, raw: "A reply once the feature is switched back on.").success?).to eq(
      false,
    )
  end

  it "stops limiting while the plugin's master switch is off" do
    slow!(user)
    reply_as(user)

    SiteSetting.jtech_enabled = false
    expect(described_class.enabled?).to eq(false)
    expect(reply_as(user, raw: "A reply while the whole plugin is switched off.").success?).to eq(
      true,
    )
  end

  describe ".interval_words" do
    it "says it in minutes and hours" do
      expect(described_class.interval_words(5.minutes.to_i)).to eq("5 minutes")
      expect(described_class.interval_words(1.hour.to_i)).to eq("1 hour")
      expect(described_class.interval_words(90.minutes.to_i)).to eq("1 hour 30 minutes")
      expect(described_class.interval_words(1.day.to_i)).to eq("24 hours")
    end
  end
end
