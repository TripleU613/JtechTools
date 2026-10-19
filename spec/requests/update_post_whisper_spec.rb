# frozen_string_literal: true

require "rails_helper"

# Verifies the PUT /discourse-mod-categories/post/:id/whisper endpoint —
# the dedicated path for toggling/changing whisper state on an EXISTING
# post (Discourse's PostsController#update drops whisper params because
# `add_permitted_post_create_param` is create-only).
#
# Critical gate: staff-only. A user editing their own post can change the
# raw via the normal update flow, but cannot arm/disarm a whisper — that
# would let a non-staff author whisper-back to add an audience after the
# fact, bypassing the same staff check that gates whisper creation.
RSpec.describe "Update post whisper" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:author, :user)
  fab!(:other_user, :user)
  fab!(:target, :user)
  fab!(:group_member, :user)
  fab!(:whisper_group) { Fabricate(:group, name: "whisper_squad") }
  fab!(:badge) { Fabricate(:badge, name: "WhisperEditBadge") }
  fab!(:badge_holder, :user)
  fab!(:topic)
  fab!(:op) { Fabricate(:post, topic: topic, user: author) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: author) }

  let(:targets_field) { DiscourseModCategories::POST_WHISPER_TARGETS_FIELD }
  let(:groups_field) { DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD }
  let(:badges_field) { DiscourseModCategories::POST_WHISPER_TARGET_BADGES_FIELD }
  let(:participants_field) { DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.mod_whisper_enabled = true
    whisper_group.add(group_member)
    BadgeGranter.grant(badge, badge_holder)
  end

  describe "arming a regular post into a whisper" do
    it "writes the target user ids onto the post" do
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
            mod_whisper_target_user_ids: [target.id],
          }

      expect(response.status).to eq(200)
      expect(post_record.reload.custom_fields[targets_field]).to eq([target.id])
    end

    it "drops invalid user ids before saving" do
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
            mod_whisper_target_user_ids: [target.id, 9_999_999],
          }

      expect(post_record.reload.custom_fields[targets_field]).to eq([target.id])
    end

    it "writes group and badge targets onto the post" do
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
            mod_whisper_target_group_ids: [whisper_group.id],
            mod_whisper_target_badge_ids: [badge.id],
          }

      expect(post_record.reload.custom_fields[groups_field]).to eq([whisper_group.id])
      expect(post_record.reload.custom_fields[badges_field]).to eq([badge.id])
    end

    it "records explicitly targeted non-staff users (only) as topic participants" do
      topic.custom_fields[participants_field] = [admin.id]
      topic.save_custom_fields(true)
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
            mod_whisper_target_user_ids: [target.id],
            mod_whisper_target_group_ids: [whisper_group.id],
            mod_whisper_target_badge_ids: [badge.id],
          }

      participants = Array(topic.reload.custom_fields[participants_field]).map(&:to_i)
      expect(participants).to include(admin.id, target.id)
      # Group members and badge holders see the whisper through their
      # membership, which is re-checked on every read — they are not
      # recorded (a participant never gains visibility anyway).
      expect(participants).not_to include(group_member.id, badge_holder.id)
    end

    it "refuses to turn a topic's first post into a whisper" do
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{op.id}/whisper.json", params: { mod_whisper: true }

      expect(response.status).to eq(400)
      expect(op.reload.custom_fields.key?(targets_field)).to eq(false)
    end

    it "returns the new whisper state in the response body" do
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
            mod_whisper_target_user_ids: [target.id],
          }

      body = response.parsed_body
      expect(body["mod_is_whisper"]).to eq(true)
      expect(body["mod_whisper_target_user_ids"]).to eq([target.id])
    end

    it "takes back the bump the post gave the topic while it was public" do
      op.update_columns(created_at: 2.hours.ago)
      post_record.update_columns(created_at: 10.minutes.ago)
      ::Topic.where(id: topic.id).update_all(bumped_at: post_record.created_at)
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
            mod_whisper_target_user_ids: [target.id],
          }

      expect(response.status).to eq(200)
      expect(topic.reload.bumped_at).to be_within(1.second).of(op.created_at)
    end

    it "doesn't hand the bump on to a later reply posted without one" do
      op.update_columns(created_at: 2.hours.ago)
      post_record.update_columns(created_at: 10.minutes.ago)
      Fabricate(:post, topic: topic, user: other_user).update_columns(created_at: 5.minutes.ago)
      ::Topic.where(id: topic.id).update_all(bumped_at: post_record.created_at)
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
            mod_whisper_target_user_ids: [target.id],
          }

      expect(topic.reload.bumped_at).to be_within(1.second).of(op.created_at)
    end

    it "leaves a bump that came later alone" do
      post_record.update_columns(created_at: 10.minutes.ago)
      ::Topic.where(id: topic.id).update_all(bumped_at: 1.minute.ago)
      bumped_at = topic.reload.bumped_at
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
            mod_whisper_target_user_ids: [target.id],
          }

      expect(topic.reload.bumped_at).to eq_time(bumped_at)
    end
  end

  describe "disarming a whisper back into a regular post" do
    before do
      post_record.custom_fields[targets_field] = [target.id]
      post_record.custom_fields[groups_field] = [whisper_group.id]
      post_record.custom_fields[badges_field] = [badge.id]
      post_record.save_custom_fields(true)
    end

    it "removes all three whisper custom fields" do
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: false,
          }

      expect(response.status).to eq(200)
      reloaded = post_record.reload
      expect(reloaded.custom_fields).not_to have_key(targets_field)
      expect(reloaded.custom_fields).not_to have_key(groups_field)
      expect(reloaded.custom_fields).not_to have_key(badges_field)
    end

    it "reports the post as no longer a whisper in the response" do
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: false,
          }

      expect(response.parsed_body["mod_is_whisper"]).to eq(false)
    end

    it "leaves the topic's bump where it is, as core does for its own whispers" do
      op.update_columns(created_at: 2.hours.ago)
      post_record.update_columns(created_at: 10.minutes.ago)
      ::Topic.where(id: topic.id).update_all(bumped_at: op.created_at)
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: false,
          }

      expect(topic.reload.bumped_at).to be_within(1.second).of(op.created_at)
    end
  end

  describe "authorization" do
    it "403s a regular user (even the post's own author)" do
      sign_in(author)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
            mod_whisper_target_user_ids: [target.id],
          }

      expect(response.status).to eq(403)
      expect(post_record.reload.custom_fields).not_to have_key(targets_field)
    end

    it "403s a different regular user" do
      sign_in(other_user)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
          }

      expect(response.status).to eq(403)
    end

    it "redirects anonymous users to login" do
      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
          }

      expect(response.status).to eq(403).or eq(404)
    end

    it "lets admins through" do
      sign_in(admin)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
            mod_whisper_target_user_ids: [target.id],
          }

      expect(response.status).to eq(200)
    end
  end

  describe "edge cases" do
    it "404s for a non-existent post" do
      sign_in(admin)
      put "/discourse-mod-categories/post/9999999/whisper.json", params: { mod_whisper: true }
      expect(response.status).to eq(404)
    end

    it "404s when mod_whisper_enabled is off" do
      SiteSetting.mod_whisper_enabled = false
      sign_in(admin)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
          }

      expect(response.status).to eq(404)
    end

    it "arms with an empty audience (staff-only whisper-back)" do
      sign_in(moderator)

      put "/discourse-mod-categories/post/#{post_record.id}/whisper.json",
          params: {
            mod_whisper: true,
          }

      expect(response.status).to eq(200)
      expect(post_record.reload.custom_fields[targets_field]).to eq([])
      expect(response.parsed_body["mod_is_whisper"]).to eq(true)
    end
  end
end
