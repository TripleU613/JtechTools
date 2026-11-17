# frozen_string_literal: true

require "rails_helper"

# mod_whisper_enabled only stops new whispers being written. A whisper
# written while it was on stays a whisper, seen by its audience only, and a
# reply to it still inherits that audience.
RSpec.describe "Whispers switched off" do
  fab!(:moderator)
  fab!(:author) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:target) { Fabricate(:user, trust_level: TrustLevel[2]) }
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
    old_whisper.custom_fields[targets_field] = [target.id]
    old_whisper.save_custom_fields(true)
    SiteSetting.mod_whisper_enabled = false
  end

  def stream_post_ids(user)
    sign_in(user)
    get "/t/#{topic.id}.json"
    expect(response.status).to eq(200)
    response.parsed_body["post_stream"]["posts"].map { |p| p["id"] }
  end

  it "keeps an existing whisper from someone it doesn't name" do
    expect(stream_post_ids(stranger)).not_to include(old_whisper.id)
    expect(Guardian.new(stranger).can_see_post?(old_whisper)).to eq(false)
  end

  it "still shows it to its target" do
    expect(stream_post_ids(target)).to include(old_whisper.id)
  end

  it "keeps it private with the whole bundle off too" do
    SiteSetting.jtech_enabled = false
    expect(stream_post_ids(stranger)).not_to include(old_whisper.id)
  end

  it "doesn't make a post staff arm into a whisper" do
    armed_post =
      PostCreator.create!(
        moderator,
        :topic_id => topic.id,
        :raw => "Staff try to arm a whisper anyway.",
        armed => "true",
        targets_field => [stranger.id],
      )

    expect(DiscourseModCategories::Whisper.whisper?(armed_post)).to eq(false)
    expect(stream_post_ids(stranger)).to include(armed_post.id)
  end

  it "keeps a reply to an old whisper inside its audience" do
    reply =
      PostCreator.create!(
        target,
        topic_id: topic.id,
        raw: "A reply to the old whisper.",
        reply_to_post_number: old_whisper.post_number,
      )

    expect(DiscourseModCategories::Whisper.whisper?(reply)).to eq(true)
    expect(Guardian.new(stranger).can_see_post?(reply)).to eq(false)
    expect(stream_post_ids(stranger)).not_to include(reply.id)
  end
end
