# frozen_string_literal: true

require "rails_helper"

# Exercises the plugin's wiring in plugin.rb: the Guardian prepend is in place,
# the master switch flips correctly, and core privileges (admin) are unaffected
# regardless of plugin state.
RSpec.describe "DiscourseModCategories plugin.rb" do
  fab!(:moderator)
  fab!(:admin)
  fab!(:user)
  fab!(:category)

  describe "Guardian prepend" do
    it "wires the GuardianExtensions module into Guardian" do
      expect(Guardian.ancestors).to include(DiscourseModCategories::GuardianExtensions)
    end
  end

  describe "master switch (mod_categories_enabled)" do
    context "when disabled (default)" do
      before { SiteSetting.mod_categories_enabled = false }

      it "denies moderators" do
        guardian = Guardian.new(moderator)
        expect(guardian.can_create_category?).to eq(false)
        expect(guardian.can_edit_category?(category)).to eq(false)
        expect(guardian.can_delete_category?(category)).to eq(false)
      end

      it "still allows admins" do
        guardian = Guardian.new(admin)
        expect(guardian.can_create_category?).to eq(true)
        expect(guardian.can_edit_category?(category)).to eq(true)
      end

      it "still denies regular users" do
        guardian = Guardian.new(user)
        expect(guardian.can_create_category?).to eq(false)
        expect(guardian.can_edit_category?(category)).to eq(false)
        expect(guardian.can_delete_category?(category)).to eq(false)
      end
    end

    context "when enabled" do
      before { SiteSetting.mod_categories_enabled = true }

      it "leaves moderator category management to core's setting" do
        empty_category = Fabricate(:category)
        guardian = Guardian.new(moderator)
        expect(guardian.can_create_category?).to eq(false)
        expect(guardian.can_edit_category?(empty_category)).to eq(false)

        SiteSetting.moderators_manage_categories = true
        guardian = Guardian.new(moderator)
        expect(guardian.can_create_category?).to eq(true)
        expect(guardian.can_edit_category?(empty_category)).to eq(true)
        expect(guardian.can_delete_category?(empty_category)).to eq(true)
      end

      it "still denies regular users" do
        guardian = Guardian.new(user)
        expect(guardian.can_create_category?).to eq(false)
        expect(guardian.can_edit_category?(category)).to eq(false)
        expect(guardian.can_delete_category?(category)).to eq(false)
      end

      it "does not change admin privileges" do
        guardian = Guardian.new(admin)
        expect(guardian.can_create_category?).to eq(true)
        expect(guardian.can_edit_category?(category)).to eq(true)
      end
    end
  end

  describe "settings registration" do
    # A new install starts with everything off (forums that already ran the
    # plugin keep them on: db/migrate/20261015000001)
    # read from settings.yml: the specs run with these on as their default
    # (spec/support/jtech_features_on.rb)
    it "starts every feature, the master switch and the theme off" do
      settings =
        YAML.load_file(File.expand_path("../config/settings.yml", __dir__)).values.reduce(:merge)
      KeepFeaturesOnForExistingInstalls::SETTINGS.each do |setting|
        expect(settings.dig(setting, "default")).to eq(false), setting
      end
    end

    it "registers precheck_new_topic_enabled defaulting to true" do
      expect(SiteSetting.defaults[:precheck_new_topic_enabled]).to eq(true)
    end

    it "registers topic_footer_message_enabled defaulting to true" do
      expect(SiteSetting.defaults[:topic_footer_message_enabled]).to eq(true)
    end

    it "registers topic_reply_prompt_enabled defaulting to true" do
      expect(SiteSetting.defaults[:topic_reply_prompt_enabled]).to eq(true)
    end

    it "exposes the feature toggles to the client" do
      client_settings = SiteSetting.client_settings
      expect(client_settings).to include(:precheck_new_topic_enabled)
      expect(client_settings).to include(:topic_footer_message_enabled)
      expect(client_settings).to include(:topic_reply_prompt_enabled)
    end
  end

  describe "per-feature moderator toggle registration" do
    it "registers a toggle for every moderator grant, defaulting to current behavior" do
      %i[
        mod_whisper_add_participant_enabled
        mod_whisper_convert_enabled
        mod_whisper_badge_targeting_enabled
        mod_topic_private_notes_enabled
        mod_note_view_tracking_enabled
        mod_notes_feed_enabled
        mod_notify_staff_on_topic_notes
        mod_pin_post_enabled
        mod_topic_require_reply_approval_enabled
        mod_pm_badge_group_enabled
        mod_first_post_checklist_enabled
        mod_targeted_checklists_enabled
        mod_topic_prompt_checklist_enabled
        mod_notify_whisper_targets
        mod_whisper_audience_aware_topic_list
        mini_mod_can_create_categories
        mini_mod_can_edit_categories
        mini_mod_can_edit_topics
        mini_mod_can_move_topics
      ].each { |setting| expect(SiteSetting.defaults[setting]).to eq(true), setting.to_s }
    end

    it "defaults cross-staff note editing to off (security fix)" do
      expect(SiteSetting.defaults[:mod_moderators_can_edit_others_notes]).to eq(false)
    end

    it "keeps the mini-mod settings off the client payload" do
      client_settings = SiteSetting.client_settings
      expect(client_settings).not_to include(:mini_mod_enabled)
      expect(client_settings).not_to include(:mini_mod_manage_all_categories)
      expect(client_settings).not_to include(:mini_mod_manage_tags)
    end
  end

  describe "translator-tweaks settings registration" do
    it "defaults the worker URL to the proxy the module used to hard-code" do
      expect(SiteSetting.defaults[:translator_tweaks_worker_url]).to eq(
        "https://google-translate-worker.abesternheim.workers.dev/language/translate/v2",
      )
    end

    it "keeps the translator settings off the client payload" do
      client_settings = SiteSetting.client_settings
      expect(client_settings).not_to include(:translator_tweaks_enabled)
      expect(client_settings).not_to include(:translator_tweaks_worker_url)
    end
  end

  describe "disteleplus settings registration" do
    it "registers the module master switch, off by default" do
      expect(SiteSetting.defaults[:disteleplus_enabled]).to eq(false)
    end

    it "registers the bridge feature toggles with their defaults" do
      expect(SiteSetting.defaults[:disteleplus_bridge_uploads]).to eq(true)
      expect(SiteSetting.defaults[:disteleplus_bridge_edits]).to eq(true)
      expect(SiteSetting.defaults[:disteleplus_bridge_deletes]).to eq(true)
      expect(SiteSetting.defaults[:disteleplus_bridge_polls]).to eq(true)
      expect(SiteSetting.defaults[:disteleplus_bridge_reactions]).to eq(true)
      expect(SiteSetting.defaults[:disteleplus_max_upload_mb]).to eq(10)
      expect(SiteSetting.defaults[:disteleplus_forum_uploads_enabled]).to eq(false)
      expect(SiteSetting.defaults[:disteleplus_setup_commands_enabled]).to eq(true)
      expect(SiteSetting.defaults[:disteleplus_forum_upload_topic_name]).to eq("Uploads")
      expect(SiteSetting.defaults[:disteleplus_forum_upload_max_mb]).to eq(50)
      expect(SiteSetting.defaults[:disteleplus_forum_upload_backfill_batch_size]).to eq(25)
      expect(SiteSetting.defaults[:disteleplus_forum_upload_backfill_spacing_seconds]).to eq(4)
    end

    it "registers the access, notification and voice-note settings with their defaults" do
      expect(SiteSetting.defaults[:disteleplus_allowed_groups]).to eq("3")
      expect(SiteSetting.defaults[:disteleplus_chat_channel_id]).to eq(0)
      expect(SiteSetting.defaults[:disteleplus_force_channel_notifications]).to eq(true)
      expect(SiteSetting.defaults[:disteleplus_notification_sync_now]).to eq(false)
      expect(SiteSetting.defaults[:disteleplus_voice_notes_enabled]).to eq(true)
      expect(SiteSetting.defaults[:disteleplus_voice_note_max_seconds]).to eq(300)
      expect(SiteSetting.defaults[:disteleplus_voice_notes_bridge_channel_only]).to eq(true)
      expect(SiteSetting.defaults[:disteleplus_voice_player_all_audio]).to eq(true)
    end

    it "exposes exactly the client-needed settings to the client" do
      client_settings = SiteSetting.client_settings
      expect(client_settings).to include(:disteleplus_enabled)
      expect(client_settings).to include(:disteleplus_voice_notes_enabled)
      expect(client_settings).to include(:disteleplus_voice_note_max_seconds)
      expect(client_settings).to include(:disteleplus_voice_player_all_audio)
      # Chat-era settings are hidden server-side leftovers, never shipped to
      # the browser; the native UI derives access from the current user.
      expect(client_settings).not_to include(:disteleplus_chat_channel_id)
      expect(client_settings).not_to include(:disteleplus_lock_chat_ui)
      expect(client_settings).not_to include(:disteleplus_chat_button_opens_bridge)
      expect(client_settings).not_to include(:disteleplus_bot_token)
      expect(client_settings).not_to include(:disteleplus_webhook_secret)
      expect(client_settings).not_to include(:disteleplus_notification_sync_now)
    end
  end

  describe "moderator-messages Guardian" do
    before { SiteSetting.mod_categories_enabled = true }

    it "lets moderators manage the moderator messages" do
      expect(Guardian.new(moderator).can_manage_mod_messages?).to eq(true)
    end

    it "lets admins manage the moderator messages" do
      expect(Guardian.new(admin).can_manage_mod_messages?).to eq(true)
    end

    it "does not let regular users manage the moderator messages" do
      expect(Guardian.new(user).can_manage_mod_messages?).to eq(false)
    end

    it "does not let anonymous users manage the moderator messages" do
      expect(Guardian.new(nil).can_manage_mod_messages?).to eq(false)
    end

    it "denies moderators when the plugin master switch is off" do
      SiteSetting.mod_categories_enabled = false
      expect(Guardian.new(moderator).can_manage_mod_messages?).to eq(false)
    end
  end
end
