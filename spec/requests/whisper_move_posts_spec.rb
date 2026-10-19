# frozen_string_literal: true

require "rails_helper"

# Moving posts with "keep the original" (freeze_original) copies each reply
# with Post#dup, which leaves custom fields behind: a whisper's copy came out
# in the destination topic as an ordinary public post. Staff, trust level 4
# and category moderators can all reach it through POST /t/:id/move-posts.
RSpec.describe "Moving whispers" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:author) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:target) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:stranger) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:leader) { Fabricate(:user, trust_level: TrustLevel[4]) }
  fab!(:category)
  fab!(:op) { create_post(user: author, category: category, raw: "The topic the whisper is in.") }
  fab!(:destination_op) do
    create_post(user: author, category: category, raw: "The topic the whisper goes to.")
  end

  let(:topic) { op.topic }
  let(:destination) { destination_op.topic }
  let(:secret) { "copiedwhispertoucan" }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.mod_whisper_enabled = true
    SiteSetting.min_post_length = 5
    SiteSetting.body_min_entropy = 1
    Group.refresh_automatic_groups!
  end

  def whisper!(to:, raw:, reply_to: nil)
    PostCreator.create!(
      moderator,
      :topic_id => topic.id,
      :raw => raw,
      :reply_to_post_number => reply_to&.post_number,
      DiscourseModCategories::POST_WHISPER_ARMED_PARAM => "true",
      DiscourseModCategories::POST_WHISPER_TARGETS_FIELD => to.map(&:id),
    )
  end

  def move!(*posts, by: admin, freeze_original: true)
    sign_in(by)
    post "/t/#{topic.id}/move-posts.json",
         params: {
           post_ids: posts.map(&:id),
           destination_topic_id: destination.id,
           freeze_original: freeze_original,
         }
    expect(response.status).to eq(200)
    posts.map { |p| Post.find(MovedPost.find_by(old_post_id: p.id).new_post_id) }
  end

  def stream_ids(viewer)
    sign_in(viewer)
    get "/t/#{destination.id}.json"
    expect(response.status).to eq(200)
    response.parsed_body["post_stream"]["posts"].map { |p| p["id"] }
  end

  let!(:whisper) { whisper!(to: [target], raw: "Only for you: #{secret} is the code.") }

  describe "copying a whisper" do
    it "keeps the copy hidden from people outside its audience" do
      copy = move!(whisper).first

      expect(copy.id).not_to eq(whisper.id)
      expect(stream_ids(stranger)).not_to include(copy.id)
      expect(response.body).not_to include(secret)

      get "/posts/#{copy.id}.json"
      expect(response.status).to eq(404)
    end

    it "shows the copy to its audience, as a whisper to the same people" do
      copy = move!(whisper).first

      expect(stream_ids(target)).to include(copy.id)
      shown = response.parsed_body["post_stream"]["posts"].find { |p| p["id"] == copy.id }
      expect(shown["mod_is_whisper"]).to eq(true)
      expect(shown["mod_whisper_target_user_ids"]).to eq([target.id])

      get "/posts/#{copy.id}.json"
      expect(response.status).to eq(200)
      expect(response.parsed_body["raw"]).to include(secret)
    end

    it "keeps an admin's whisper from moderators it doesn't name" do
      admins_whisper =
        PostCreator.create!(
          admin,
          :topic_id => topic.id,
          :raw => "Admins and you only.",
          DiscourseModCategories::POST_WHISPER_ARMED_PARAM => "true",
          DiscourseModCategories::POST_WHISPER_TARGETS_FIELD => [target.id],
        )

      copy = move!(admins_whisper).first

      expect(stream_ids(moderator)).not_to include(copy.id)
      expect(stream_ids(target)).to include(copy.id)
    end

    it "leaves a trust level 4 member who copies a whisper they can't see unable to read it" do
      copy = move!(whisper, by: leader).first

      expect(stream_ids(leader)).not_to include(copy.id)
      get "/posts/#{copy.id}.json"
      expect(response.status).to eq(404)
    end

    it "leaves the destination's counters, bump and last poster as they were" do
      destination.update_columns(bumped_at: 1.day.ago)
      before = destination.reload.slice(:highest_post_number, :posts_count, :last_post_user_id)
      bumped_at = destination.bumped_at

      copy = move!(whisper).first

      destination.reload
      expect(destination.slice(:highest_post_number, :posts_count, :last_post_user_id)).to eq(
        before,
      )
      expect(destination.bumped_at).to eq_time(bumped_at)
      expect(destination.highest_staff_post_number).to eq(copy.post_number)
    end

    it "keeps the copy out of search" do
      SearchIndexer.enable
      copy = move!(whisper).first

      expect(PostSearchData.where(post_id: copy.id)).not_to exist
    ensure
      SearchIndexer.disable
    end

    it "keeps the copy's links out of the destination's topic map" do
      linking = whisper!(to: [target], raw: "Only for you: https://example.com/hidden-place")

      copy = move!(linking).first
      TopicLink.extract_from(copy.reload)

      expect(TopicLink.where(topic_id: destination.id)).not_to exist
    end

    it "doesn't count a copied whisper among the replies of the post it answers" do
      question = create_post(user: author, topic: topic, raw: "A public question here.")
      answer = whisper!(to: [author], raw: "A private answer.", reply_to: question)
      expect(question.reload.reply_count).to eq(0)

      question_copy, answer_copy = move!(question, answer)

      expect(answer_copy.reply_to_post_number).to eq(question_copy.post_number)
      expect(question_copy.reload.reply_count).to eq(0)
    end

    it "lets the people it's addressed to whisper back to staff in the destination" do
      move!(whisper)

      expect(Guardian.new(target).can_whisper_in_topic?(destination.reload)).to eq(true)
      expect(Guardian.new(stranger).can_whisper_in_topic?(destination)).to eq(false)
    end

    it "stays hidden with the plugin switched off" do
      SiteSetting.jtech_enabled = false

      copy = move!(whisper).first

      expect(DiscourseModCategories::Whisper.whisper?(copy.reload)).to eq(true)
      expect(Guardian.new(stranger).can_see_post?(copy)).to eq(false)
    end
  end

  describe "moving a whisper" do
    it "doesn't bump the destination or make the whisper its last post" do
      destination.update_columns(bumped_at: 1.day.ago)
      bumped_at = destination.reload.bumped_at

      moved = move!(whisper, freeze_original: false).first

      expect(moved.id).to eq(whisper.id)
      expect(stream_ids(stranger)).not_to include(moved.id)
      destination.reload
      expect(destination.bumped_at).to eq_time(bumped_at)
      expect(destination.last_post_user_id).to eq(author.id)
    end
  end
end
