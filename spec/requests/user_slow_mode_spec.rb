# frozen_string_literal: true

require "rails_helper"

# Setting and lifting a user's slow mode from their admin page: who may, what
# it records (staff log, the user's message), and what the browser is told.
RSpec.describe "User slow mode" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:user) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[2]) }

  let(:path) { "/discourse-mod-categories/user/#{user.id}/slow-mode.json" }
  let(:params) { { seconds: 900, ends_at: 1.week.from_now.iso8601, reason: "Too many posts at once" } }

  before { SiteSetting.mod_categories_enabled = true }

  def slow_mode_of(target)
    DiscourseModCategories::UserSlowMode.state_for(target.reload)
  end

  def last_message_to(target)
    Topic
      .private_messages_for_user(target)
      .where(user_id: Discourse.system_user.id)
      .order(:created_at)
      .last
  end

  describe "PUT /discourse-mod-categories/user/:user_id/slow-mode" do
    it "lets an admin put a user in slow mode, logs it and tells the user why" do
      sign_in(admin)

      put path, params: params

      expect(response.status).to eq(200)
      expect(response.parsed_body["slow_mode"]["seconds"]).to eq(900)
      state = slow_mode_of(user)
      expect(state.seconds).to eq(900)
      expect(state.ends_at).to be_within(1.minute).of(1.week.from_now)

      log = UserHistory.find_by(custom_type: "mod_user_slow_mode_set")
      expect(log.acting_user_id).to eq(admin.id)
      expect(log.target_user_id).to eq(user.id)
      expect(log.details).to include("interval: 15 minutes", "reason: Too many posts at once")

      message = last_message_to(user)
      expect(message.title).to eq(
        I18n.t("system_messages.mod_user_slow_mode_set.subject_template"),
      )
      expect(message.first_post.raw).to include("15 minutes", "Too many posts at once")
    end

    it "takes no end date" do
      sign_in(admin)

      put path, params: params.merge(ends_at: "")

      expect(response.status).to eq(200)
      expect(slow_mode_of(user).ends_at).to be_nil
      expect(last_message_to(user).first_post.raw).to include(
        I18n.t("discourse_mod_categories.slow_mode.no_end"),
      )
    end

    it "lets a moderator do it while moderators may" do
      sign_in(moderator)

      put path, params: params

      expect(response.status).to eq(200)
      expect(slow_mode_of(user)).to be_present
    end

    it "doesn't let a moderator set or lift it when only admins may" do
      SiteSetting.mod_user_slow_mode_moderators = false
      DiscourseModCategories::UserSlowMode.set!(
        user,
        actor: admin,
        seconds: 900,
        ends_at: nil,
        reason: "Set by an admin",
      )
      sign_in(moderator)

      put path, params: params.merge(seconds: 60)
      expect(response.status).to eq(403)
      delete path
      expect(response.status).to eq(403)

      expect(slow_mode_of(user).seconds).to eq(900)
    end

    it "doesn't let a regular user use it, on themselves or anyone else" do
      sign_in(other_user)

      put path, params: params
      expect(response.status).to eq(403)
      put "/discourse-mod-categories/user/#{other_user.id}/slow-mode.json", params: params
      expect(response.status).to eq(403)

      expect(slow_mode_of(user)).to be_nil
      expect(slow_mode_of(other_user)).to be_nil
    end

    it "can't be put on staff" do
      sign_in(admin)

      put "/discourse-mod-categories/user/#{moderator.id}/slow-mode.json", params: params

      expect(response.status).to eq(403)
      expect(slow_mode_of(moderator)).to be_nil
    end

    it "needs a reason, a sensible interval and an end in the future" do
      sign_in(admin)

      put path, params: params.merge(reason: "  ")
      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(
        [I18n.t("discourse_mod_categories.slow_mode.errors.reason")],
      )

      put path, params: params.merge(seconds: 30)
      expect(response.status).to eq(422)
      put path, params: params.merge(seconds: 90)
      expect(response.status).to eq(422)
      put path, params: params.merge(seconds: 8.days.to_i)
      expect(response.status).to eq(422)

      put path, params: params.merge(ends_at: 1.hour.ago.iso8601)
      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(
        [I18n.t("discourse_mod_categories.slow_mode.errors.ends_at")],
      )

      expect(slow_mode_of(user)).to be_nil
    end

    it "is not found while the feature is off" do
      SiteSetting.mod_user_slow_mode_enabled = false
      sign_in(admin)

      put path, params: params

      expect(response.status).to eq(404)
    end

    it "is not found for a user who doesn't exist" do
      sign_in(admin)

      put "/discourse-mod-categories/user/#{User.maximum(:id) + 100}/slow-mode.json", params: params

      expect(response.status).to eq(404)
    end
  end

  describe "DELETE /discourse-mod-categories/user/:user_id/slow-mode" do
    before do
      DiscourseModCategories::UserSlowMode.set!(
        user,
        actor: admin,
        seconds: 900,
        ends_at: nil,
        reason: "Too many posts at once",
      )
    end

    it "lifts it, logs it and tells the user" do
      sign_in(moderator)

      delete path

      expect(response.status).to eq(200)
      expect(slow_mode_of(user)).to be_nil
      log = UserHistory.find_by(custom_type: "mod_user_slow_mode_lifted")
      expect(log.acting_user_id).to eq(moderator.id)
      expect(log.target_user_id).to eq(user.id)
      expect(last_message_to(user).title).to eq(
        I18n.t("system_messages.mod_user_slow_mode_lifted.subject_template"),
      )
    end

    it "does nothing, and sends nothing, when there's no slow mode to lift" do
      sign_in(admin)

      expect {
        delete "/discourse-mod-categories/user/#{other_user.id}/slow-mode.json"
      }.not_to change { UserHistory.count }
      expect(response.status).to eq(200)
      expect(last_message_to(other_user)).to be_nil
    end
  end

  describe "GET /discourse-mod-categories/slow-mode" do
    it "tells a user in slow mode how often, and when they can next post" do
      DiscourseModCategories::UserSlowMode.set!(
        user,
        actor: admin,
        seconds: 900,
        ends_at: nil,
        reason: "Too many posts at once",
      )
      Fabricate(:post, user: user, created_at: 5.minutes.ago)
      sign_in(user)

      get "/discourse-mod-categories/slow-mode.json"

      expect(response.status).to eq(200)
      slow_mode = response.parsed_body["slow_mode"]
      expect(slow_mode["seconds"]).to eq(900)
      expect(Time.zone.parse(slow_mode["next_post_at"])).to be_within(1.minute).of(
        10.minutes.from_now,
      )
      expect(slow_mode["waiting"]).to eq(false)
    end

    it "says nothing to a user who isn't in slow mode" do
      sign_in(other_user)

      get "/discourse-mod-categories/slow-mode.json"

      expect(response.parsed_body["slow_mode"]).to be_nil
    end
  end

  describe "serializers" do
    before do
      DiscourseModCategories::UserSlowMode.set!(
        user,
        actor: admin,
        seconds: 3600,
        ends_at: nil,
        reason: "Too many posts at once",
      )
    end

    it "gives the user their own slow mode, for their composer" do
      json = CurrentUserSerializer.new(user, scope: Guardian.new(user), root: false).as_json

      expect(json[:mod_slow_mode][:seconds]).to eq(3600)
    end

    it "shows staff the user's slow mode on their admin page, and whether they may change it" do
      sign_in(moderator)

      get "/admin/users/#{user.id}.json"

      expect(response.parsed_body["mod_slow_mode"]["seconds"]).to eq(3600)
      expect(response.parsed_body["can_set_mod_slow_mode"]).to eq(true)

      SiteSetting.mod_user_slow_mode_moderators = false
      get "/admin/users/#{user.id}.json"
      expect(response.parsed_body["can_set_mod_slow_mode"]).to eq(false)
    end
  end
end
