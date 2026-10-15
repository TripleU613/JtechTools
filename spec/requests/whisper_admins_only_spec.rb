# frozen_string_literal: true

require "rails_helper"

# An admin's whisper reaches moderators only as targets (by user, group or
# badge), like anybody else; so does anything answering one. A moderator's
# whisper, and an admin's unarmed reply into one, stay visible to every
# moderator.
RSpec.describe "Admins' whispers" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:other_moderator, :moderator)
  fab!(:author, :user)
  fab!(:target, :user)
  fab!(:topic)
  fab!(:op) { Fabricate(:post, topic: topic, user: author) }

  let(:targets_field) { DiscourseModCategories::POST_WHISPER_TARGETS_FIELD }
  let(:groups_field) { DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD }
  let(:armed_param) { DiscourseModCategories::POST_WHISPER_ARMED_PARAM }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.mod_whisper_enabled = true
    SiteSetting.min_post_length = 5
    SiteSetting.body_min_entropy = 1
    SiteSetting.auto_silence_fast_typers_on_first_post = false
    Group.refresh_automatic_groups!
    SiteSetting.approve_unless_allowed_groups = Group::AUTO_GROUPS[:trust_level_0].to_s
  end

  def create_post(user, params = {})
    sign_in(user)
    post "/posts.json",
         params: { topic_id: topic.id, raw: "A whisper body long enough to be valid." }.merge(
           params,
         )
    expect(response.status).to eq(200)
    Post.find(response.parsed_body["id"])
  end

  def whisper_from(user, targets: [target.id], groups: [])
    create_post(user, { armed_param => true, targets_field => targets, groups_field => groups })
  end

  def stream_post_ids(user)
    sign_in(user)
    get "/t/#{topic.id}.json"
    response.parsed_body["post_stream"]["posts"].map { |p| p["id"] }
  end

  it "hides an admin's whisper from moderators it doesn't name" do
    whisper = whisper_from(admin)

    expect(DiscourseModCategories::Whisper.admins_only?(whisper)).to eq(true)
    expect(Guardian.new(moderator).can_see_post?(whisper)).to eq(false)
    expect(Guardian.new(admin).can_see_post?(whisper)).to eq(true)
    expect(Guardian.new(target).can_see_post?(whisper)).to eq(true)
    expect(stream_post_ids(moderator)).not_to include(whisper.id)
    expect(stream_post_ids(target)).to include(whisper.id)
    expect(DiscourseModCategories::Whisper.hidden_post_ids([whisper.id], moderator)).to eq(
      [whisper.id],
    )
    expect(DiscourseModCategories::Whisper.audience_user_ids(whisper)).not_to include(moderator.id)
  end

  it "shows it to a moderator it names, by user or through the moderators group" do
    by_user = whisper_from(admin, targets: [moderator.id])
    by_group = whisper_from(admin, targets: [], groups: [Group::AUTO_GROUPS[:moderators]])

    expect(Guardian.new(moderator).can_see_post?(by_user)).to eq(true)
    expect(Guardian.new(other_moderator).can_see_post?(by_user)).to eq(false)
    expect(stream_post_ids(moderator)).to include(by_user.id, by_group.id)
    expect(stream_post_ids(other_moderator)).to include(by_group.id)
  end

  it "keeps a reply to an admin's whisper from the moderators too" do
    whisper = whisper_from(admin)
    reply = create_post(target, reply_to_post_number: whisper.post_number)

    expect(DiscourseModCategories::Whisper.whisper?(reply)).to eq(true)
    expect(DiscourseModCategories::Whisper.admins_only?(reply)).to eq(true)
    expect(Guardian.new(moderator).can_see_post?(reply)).to eq(false)
    expect(Guardian.new(admin).can_see_post?(reply)).to eq(true)
  end

  it "leaves a moderator's whisper, and an admin's reply into it, to every moderator" do
    whisper = whisper_from(moderator)
    reply = create_post(admin, reply_to_post_number: whisper.post_number)

    expect(DiscourseModCategories::Whisper.admins_only?(whisper)).to eq(false)
    expect(DiscourseModCategories::Whisper.whisper?(reply)).to eq(true)
    expect(DiscourseModCategories::Whisper.admins_only?(reply)).to eq(false)
    expect(stream_post_ids(other_moderator)).to include(whisper.id, reply.id)
  end

  it "doesn't let a moderator add themselves to an admin's whisper" do
    whisper = whisper_from(admin)
    sign_in(moderator)

    post "/discourse-mod-categories/topic/#{topic.id}/whisper-participant.json",
         params: {
           post_id: whisper.id,
           user_id: moderator.id,
         }

    expect(response.status).to eq(400)
    expect(whisper.reload.custom_fields[targets_field].map(&:to_i)).not_to include(moderator.id)
  end
end
