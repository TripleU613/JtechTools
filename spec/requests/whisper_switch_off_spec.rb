# frozen_string_literal: true

require "rails_helper"

# With mod_whisper_enabled off the plugin changes nothing: an existing
# whisper is an ordinary post, and no new post becomes one.
RSpec.describe "Whispers switched off" do
  fab!(:moderator)
  fab!(:author) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:stranger) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:op) { Fabricate(:post, topic: topic, user: author, raw: "The opening post of this topic.") }
  fab!(:old_whisper) do
    Fabricate(:post, topic: topic, user: moderator, raw: "An old whisper, for the record.")
  end

  let(:targets_field) { DiscourseModCategories::POST_WHISPER_TARGETS_FIELD }
  let(:armed) { DiscourseModCategories::POST_WHISPER_ARMED_PARAM }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.min_post_length = 5
    SiteSetting.body_min_entropy = 1
    SiteSetting.auto_silence_fast_typers_on_first_post = false
    old_whisper.custom_fields[targets_field] = []
    old_whisper.save_custom_fields(true)
    SiteSetting.mod_whisper_enabled = false
  end

  it "shows an existing whisper to everyone, without its banner fields" do
    sign_in(stranger)
    get "/t/#{topic.id}.json"
    expect(response.status).to eq(200)

    post = response.parsed_body["post_stream"]["posts"].find { |p| p["id"] == old_whisper.id }
    expect(post).to be_present
    expect(post["mod_is_whisper"]).to eq(false)
    expect(post).not_to have_key("mod_whisper_targets")
  end

  it "writes no whisper, whether staff arm one or a post answers an old one" do
    armed_post =
      PostCreator.create!(
        moderator,
        :topic_id => topic.id,
        :raw => "Staff try to arm a whisper anyway.",
        armed => "true",
        targets_field => [stranger.id],
      )
    reply =
      PostCreator.create!(
        stranger,
        topic_id: topic.id,
        raw: "A reply to the old whisper.",
        reply_to_post_number: old_whisper.post_number,
      )

    expect(
      PostCustomField.where(post_id: [armed_post.id, reply.id], name: targets_field),
    ).to be_empty
    expect(reply.reload.reply_to_post_number).to eq(old_whisper.post_number)
    expect(topic.reload.highest_post_number).to eq(reply.post_number)
  end

  it "lets search index it" do
    SearchIndexer.enable
    SearchIndexer.index(old_whisper, force: true)
    expect(PostSearchData.exists?(post_id: old_whisper.id)).to eq(true)
  ensure
    SearchIndexer.disable
  end

  it "makes it a whisper again when they're switched back on" do
    expect(Guardian.new(stranger).can_see_post?(old_whisper)).to eq(true)

    SiteSetting.mod_whisper_enabled = true
    expect(Guardian.new(stranger).can_see_post?(old_whisper.reload)).to eq(false)
  end
end
