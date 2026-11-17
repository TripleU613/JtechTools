# frozen_string_literal: true

require "rails_helper"

# Guardian coverage for the moderator whisper feature: who can see a whisper
# post, and who may whisper in a topic.
RSpec.describe "Whisper Guardian" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:author, :user)
  fab!(:target, :user)
  fab!(:participant, :user)
  fab!(:stranger, :user)
  fab!(:group_member, :user)
  fab!(:topic)
  fab!(:post) { Fabricate(:post, topic: topic, user: author) }
  fab!(:whisper_group) { Fabricate(:group, name: "whisper_squad") }

  let(:targets_field) { DiscourseModCategories::POST_WHISPER_TARGETS_FIELD }
  let(:groups_field) { DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD }
  let(:participants_field) { DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.mod_whisper_enabled = true
  end

  def make_whisper(target_ids, group_ids = [])
    post.custom_fields[targets_field] = target_ids
    post.custom_fields[groups_field] = group_ids
    post.save_custom_fields(true)
    post.reload
  end

  def add_participants(ids)
    topic.custom_fields[participants_field] = ids
    topic.save_custom_fields(true)
    topic.reload
  end

  describe "#can_see_post?" do
    it "is unaffected when the post is not a whisper" do
      expect(Guardian.new(stranger).can_see_post?(post)).to eq(true)
    end

    context "with a targeted whisper" do
      before do
        make_whisper([target.id])
        add_participants([target.id])
      end

      it "lets the author see it" do
        expect(Guardian.new(author).can_see_post?(post)).to eq(true)
      end

      it "lets a target see it" do
        expect(Guardian.new(target).can_see_post?(post)).to eq(true)
      end

      it "lets staff see it for oversight" do
        expect(Guardian.new(admin).can_see_post?(post)).to eq(true)
        expect(Guardian.new(moderator).can_see_post?(post)).to eq(true)
      end

      it "hides it from a stranger" do
        expect(Guardian.new(stranger).can_see_post?(post)).to eq(false)
      end

      it "hides it from an anonymous viewer without raising" do
        expect { Guardian.new.can_see_post?(post) }.not_to raise_error
        expect(Guardian.new.can_see_post?(post)).to eq(false)
        expect(Guardian.new(nil).can_see_post?(post)).to eq(false)
      end
    end

    context "with a group-targeted whisper" do
      before do
        whisper_group.add(group_member)
        make_whisper([], [whisper_group.id])
      end

      it "lets a member of the target group see it" do
        expect(Guardian.new(group_member).can_see_post?(post)).to eq(true)
      end

      it "hides it from a non-member non-staff user" do
        expect(Guardian.new(stranger).can_see_post?(post)).to eq(false)
      end

      it "still lets staff see it for oversight" do
        expect(Guardian.new(admin).can_see_post?(post)).to eq(true)
      end

      it "lets the author see it" do
        expect(Guardian.new(author).can_see_post?(post)).to eq(true)
      end
    end

    context "with a topic whisper participant" do
      before do
        make_whisper([target.id])
        add_participants([target.id, participant.id])
      end

      # A participant (someone staff whispered to elsewhere in the topic) is
      # NOT in this whisper's audience. This used to leak every whisper in a
      # topic to everyone who had ever been whispered to there.
      it "hides the whisper from a topic participant it doesn't name" do
        expect(Guardian.new(participant).can_see_post?(post)).to eq(false)
      end

      it "hides a staff-only whisper-back from other participants" do
        make_whisper([])
        expect(Guardian.new(target).can_see_post?(post)).to eq(false)
        expect(Guardian.new(participant).can_see_post?(post)).to eq(false)
      end
    end

    context "with a staff-only whisper-back (empty targets)" do
      before { make_whisper([]) }

      it "is still treated as a whisper (key presence)" do
        expect(Guardian.new(stranger).can_see_post?(post)).to eq(false)
      end

      it "lets staff see it" do
        expect(Guardian.new(admin).can_see_post?(post)).to eq(true)
      end

      it "lets the author see it" do
        expect(Guardian.new(author).can_see_post?(post)).to eq(true)
      end
    end

    context "when the feature is disabled" do
      before do
        SiteSetting.mod_whisper_enabled = false
        make_whisper([target.id])
      end

      # Switching the feature off must never publish existing whispers.
      it "keeps existing whispers private" do
        expect(Guardian.new(stranger).can_see_post?(post)).to eq(false)
        expect(Guardian.new.can_see_post?(post)).to eq(false)
        expect(Guardian.new(target).can_see_post?(post)).to eq(true)
      end

      it "keeps them private when the whole bundle is off too" do
        SiteSetting.jtech_enabled = false
        expect(Guardian.new(stranger).can_see_post?(post)).to eq(false)
      end
    end
  end

  describe "#can_whisper_in_topic?" do
    it "lets staff whisper in any topic" do
      expect(Guardian.new(admin).can_whisper_in_topic?(topic)).to eq(true)
      expect(Guardian.new(moderator).can_whisper_in_topic?(topic)).to eq(true)
    end

    it "denies a non-participant non-staff user" do
      expect(Guardian.new(stranger).can_whisper_in_topic?(topic)).to eq(false)
    end

    it "lets a recorded topic whisper participant whisper back" do
      add_participants([participant.id])
      expect(Guardian.new(participant).can_whisper_in_topic?(topic)).to eq(true)
    end

    it "denies anonymous viewers without raising" do
      expect { Guardian.new.can_whisper_in_topic?(topic) }.not_to raise_error
      expect(Guardian.new.can_whisper_in_topic?(topic)).to eq(false)
    end

    it "denies everyone when the feature is disabled" do
      SiteSetting.mod_whisper_enabled = false
      add_participants([participant.id])
      expect(Guardian.new(admin).can_whisper_in_topic?(topic)).to eq(false)
      expect(Guardian.new(participant).can_whisper_in_topic?(topic)).to eq(false)
    end
  end
end
