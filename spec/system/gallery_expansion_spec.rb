# frozen_string_literal: true

require "rails_helper"

# Expanded screenshot gallery for the discourse-mod plugin. Every example
# captures one or more screenshots showing a genuinely different visual
# state for a feature, complementing the dedicated per-feature system specs.
# Screenshot numbers start at 104 to avoid collisions with the existing
# gallery (which runs through ~103). All screenshots are written to
# tmp/capybara/ and uploaded by CI as the `ui-screenshots` artifact.
RSpec.describe "Gallery expansion" do
  fab!(:admin)
  fab!(:moderator) { Fabricate(:moderator, username: "mod_morgan") }
  fab!(:other_moderator) { Fabricate(:moderator, username: "mod_misha") }
  fab!(:user)
  fab!(:tl0_user) { Fabricate(:user, trust_level: TrustLevel[0], refresh_auto_groups: true) }
  fab!(:tl1_user) { Fabricate(:user, trust_level: TrustLevel[1], refresh_auto_groups: true) }
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category, title: "Share your app build here") }
  fab!(:first_post) { Fabricate(:post, topic: topic, raw: "Drop your app uploads in this thread.") }

  NS = DiscourseModCategories::CHECKLIST_STORE_NAMESPACE
  KEY = DiscourseModCategories::CHECKLIST_STORE_KEY
  LOG_KEY = DiscourseModCategories::CHECKLIST_LOG_KEY
  TARGETED_KEY = DiscourseModCategories::TARGETED_CHECKLISTS_KEY
  TARGETS_FIELD = DiscourseModCategories::POST_WHISPER_TARGETS_FIELD
  TARGET_GROUPS_FIELD = DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD
  PARTICIPANTS_FIELD = DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.topic_footer_message_enabled = true
    SiteSetting.topic_reply_prompt_enabled = true
    SiteSetting.precheck_new_topic_enabled = true
    SiteSetting.mod_whisper_enabled = true
    SiteSetting.min_post_length = 5
    SiteSetting.min_first_post_length = 5
    SiteSetting.min_topic_title_length = 5
    SiteSetting.body_min_entropy = 1
    SiteSetting.title_min_entropy = 1
    SiteSetting.auto_silence_fast_typers_on_first_post = false
    SiteSetting.approve_post_count = 0
    Group.refresh_automatic_groups!
    SiteSetting.approve_unless_allowed_groups = Group::AUTO_GROUPS[:trust_level_0].to_s
  end

  def shot(name)
    begin
      Timeout.timeout(8) do
        sleep 0.1 until page.evaluate_script("Array.from(document.images).every((i) => i.complete)")
      end
    rescue Timeout::Error
      # Capture anyway rather than failing the spec over a slow image.
    end
    page.save_screenshot("#{name}.png")
  end

  def open_admin_menu
    find(".toggle-admin-menu", match: :first).click
  end

  def open_mod_messages_modal
    open_admin_menu
    find(".mod-topic-messages-button").click
    expect(page).to have_css(".mod-topic-messages-modal", wait: 10)
  end

  # ---------------------------------------------------------------------------
  # Moderator category management
  # ---------------------------------------------------------------------------
  context "moderator category management" do
    before do
      # Moderator category management is core's setting.
      SiteSetting.moderators_manage_categories = true
      # The forum's layout; new sites now default to category boxes, which
      # have no .category-list.
      SiteSetting.desktop_category_page_style = "categories_and_latest_topics"
      sign_in(moderator)
    end

    it "lists categories on the categories page as a moderator" do
      Fabricate(:category, name: "Releases")
      Fabricate(:category, name: "Bug Reports")
      visit("/categories")
      expect(page).to have_css(".category-list", wait: 10)
      shot("104_moderator_categories_list")
    end

    it "shows the categories page chrome for a moderator" do
      visit("/categories")
      expect(page).to have_css(".category-list", wait: 10)
      shot("105_moderator_categories_page_chrome")
    end

    it "opens a category settings tab as a moderator" do
      visit("/c/#{category.slug}/edit/settings")
      expect(page).to have_css(".mod-new-topic-prompt", wait: 10)
      shot("106_category_edit_settings_tab")
    end

    it "opens the category general tab as a moderator" do
      visit("/c/#{category.slug}/edit/general")
      expect(page).to have_css(
        ".edit-category-tab, .category-color-editor, #edit-category-tabs",
        wait: 10,
      )
      shot("107_category_edit_general_tab")
    end

    it "opens the category security tab as a moderator" do
      visit("/c/#{category.slug}/edit/security")
      expect(page).to have_css(
        ".edit-category-tab, .edit-category-tab-security, #edit-category-tabs",
        wait: 10,
      )
      shot("108_category_edit_security_tab")
    end

    it "shows the topic list inside a category" do
      Fabricate(:topic, category: category, title: "A first conversation")
      Fabricate(:topic, category: category, title: "A second conversation")
      visit("/c/#{category.slug}/#{category.id}")
      expect(page).to have_css(".topic-list-item", wait: 10)
      shot("109_category_topic_list_view")
    end

    it "shows the category header in a topic" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      shot("110_category_badge_in_topic_header")
    end
  end

  # ---------------------------------------------------------------------------
  # Per-topic footer message — extra states
  # ---------------------------------------------------------------------------
  context "per-topic footer message — extra states" do
    before { sign_in(moderator) }

    it "renders a multi-paragraph markdown footer message" do
      topic.custom_fields[
        "mod_topic_footer_message"
      ] = "**Heads up:** post one upload per topic.\n\n" \
        "Use [this guide](https://example.com/guide) before posting."
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".topic-footer-message", wait: 10)
      shot("111_footer_multiparagraph_markdown")
    end

    it "renders a footer with a markdown link to external guidelines" do
      topic.custom_fields[
        "mod_topic_footer_message"
      ] = "Please review the [community guidelines](https://example.com/g) before posting."
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".topic-footer-message a", wait: 10)
      shot("112_footer_with_markdown_link")
    end

    it "shows the official-notice box with the shield icon" do
      topic.custom_fields[
        "mod_topic_footer_message"
      ] = "Moderation notice: only post finished app uploads here."
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".topic-footer-message", wait: 10)
      shot("113_footer_shield_icon_box")
    end

    it "shows the footer on a topic with multiple posts" do
      5.times { |i| Fabricate(:post, topic: topic, raw: "Reply number #{i} in this thread.") }
      topic.custom_fields["mod_topic_footer_message"] = "Keep replies on-topic — uploads only."
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".topic-footer-message", wait: 10)
      shot("114_footer_on_multi_post_thread")
    end

    it "shows the modal with only the footer field set (empty reply prompt)" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      open_mod_messages_modal
      find(".mod-footer-input").fill_in(with: "Only the footer — no reply prompt.")
      shot("115_modal_only_footer_field_set")
    end

    it "shows the Prompt Checklist modal in statement mode (replaces the old reply-prompt field)" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      find(".toggle-admin-menu", match: :first).click
      expect(page).to have_css(".mod-topic-prompt-checklist-button", wait: 10)
      find(".mod-topic-prompt-checklist-button").click
      expect(page).to have_css(".mod-topic-prompt-checklist-modal", wait: 10)
      shot("116_modal_only_reply_prompt_set")
    end

    it "shows a topic with a footer message and a closed banner together" do
      topic.update!(closed: true)
      topic.custom_fields[
        "mod_topic_footer_message"
      ] = "This thread is closed — see the announcement."
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".topic-footer-message", wait: 10)
      shot("117_footer_on_closed_topic_with_banner")
    end
  end

  # ---------------------------------------------------------------------------
  # Per-topic prompt checklist — extra states (replaces the old reply-prompt
  # tests; the editor now lives under the Prompt Checklist entry and the
  # statement-mode flow supersedes the legacy reply-prompt textarea.)
  # ---------------------------------------------------------------------------
  context "per-topic prompt checklist — extra states" do
    before { sign_in(moderator) }

    def open_prompt_checklist_modal
      find(".toggle-admin-menu", match: :first).click
      expect(page).to have_css(".mod-topic-prompt-checklist-button", wait: 10)
      find(".mod-topic-prompt-checklist-button").click
      expect(page).to have_css(".mod-topic-prompt-checklist-modal", wait: 10)
    end

    def switch_to_statement_mode
      # The editor defaults to checklist mode for a topic with no
      # existing config; switching to statement mode (segmented toggle)
      # reveals the statement textarea.
      find(".mod-checklist-mode-toggle button", text: "Statement").click
      expect(page).to have_css(".mod-topic-prompt-checklist-statement", wait: 10)
    end

    it "shows the statement-mode prompt with the audience dropdown at TL0" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      open_prompt_checklist_modal
      switch_to_statement_mode
      find(".mod-topic-prompt-checklist-statement").fill_in(with: "Read the rules first.")
      audience = PageObjects::Components::SelectKit.new(".mod-topic-prompt-checklist-max-tl")
      audience.expand
      audience.select_row_by_value("0")
      shot("118_reply_prompt_audience_capped_tl0")
    end

    it "shows the statement-mode prompt with the audience dropdown at TL2" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      open_prompt_checklist_modal
      switch_to_statement_mode
      find(".mod-topic-prompt-checklist-statement").fill_in(with: "Be sure your reply is on-topic.")
      audience = PageObjects::Components::SelectKit.new(".mod-topic-prompt-checklist-max-tl")
      audience.expand
      audience.select_row_by_value("2")
      shot("119_reply_prompt_audience_capped_tl2")
    end

    it "shows the modal with a long multi-line statement entered" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      open_prompt_checklist_modal
      switch_to_statement_mode
      find(".mod-topic-prompt-checklist-statement").fill_in(
        with:
          "Before replying, please check:\n" \
            "  - is this an upload?\n" \
            "  - did you search existing threads?\n" \
            "  - did you read https://example.com/guide ?",
      )
      shot("120_modal_multiline_reply_prompt")
    end

    it "pre-fills the editor in statement mode from a legacy reply prompt" do
      topic.custom_fields["mod_topic_reply_prompt"] = "Please link to your upload before replying."
      topic.custom_fields["mod_topic_reply_prompt_max_tl"] = 1
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      open_prompt_checklist_modal
      expect(find(".mod-topic-prompt-checklist-statement").value).to eq(
        "Please link to your upload before replying.",
      )
      shot("121_modal_reopened_reply_prompt_persisted")
    end
  end

  context "per-topic reply prompt — user-facing" do
    it "shows a clickable URL inside the reply confirmation dialog" do
      topic.custom_fields[
        "mod_topic_reply_prompt"
      ] = "Read https://example.com/policy and then post."
      topic.save_custom_fields(true)
      sign_in(user)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      find("#topic-footer-buttons .create", match: :first).click
      find(".d-editor-input").fill_in(with: "A reply about the policy.")
      find(".save-or-cancel .create").click
      expect(page).to have_css(".dialog-body", wait: 10)
      shot("122_reply_prompt_clickable_link_dialog")
    end

    it "does not prompt a TL4 user when the cap is TL1" do
      topic.custom_fields["mod_topic_reply_prompt"] = "Only new members get prompted."
      topic.custom_fields["mod_topic_reply_prompt_max_tl"] = 1
      topic.save_custom_fields(true)
      leader = Fabricate(:user, trust_level: TrustLevel[4], refresh_auto_groups: true)
      sign_in(leader)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      find("#topic-footer-buttons .create", match: :first).click
      find(".d-editor-input").fill_in(with: "A reply from a TL4 leader.")
      find(".save-or-cancel .create").click
      # No dialog appears — the cap exempts this user.
      expect(page).to have_no_css(".dialog-body", wait: 5)
      shot("123_reply_prompt_skipped_above_cap")
    end
  end

  # ---------------------------------------------------------------------------
  # Per-category new-topic prompt — extra states
  # ---------------------------------------------------------------------------
  context "per-category new-topic prompt — extra states" do
    before do
      # The prompt lives on the category settings screen, which moderators
      # reach through core's moderators_manage_categories.
      SiteSetting.moderators_manage_categories = true
      sign_in(moderator)
    end

    it "shows a live preview with a markdown bold and a link" do
      visit("/c/#{category.slug}/edit/settings")
      expect(page).to have_css(".mod-new-topic-prompt", wait: 10)
      find(".mod-new-topic-prompt-input").fill_in(
        with: "**Important:** check https://example.com/rules before starting a thread.",
      )
      expect(page).to have_css(".mod-prompt-preview", wait: 10)
      shot("124_category_prompt_preview_bold_link")
    end

    it "shows a multi-line preview rendering line breaks" do
      visit("/c/#{category.slug}/edit/settings")
      expect(page).to have_css(".mod-new-topic-prompt", wait: 10)
      find(".mod-new-topic-prompt-input").fill_in(
        with: "Line one of the prompt.\nLine two.\nLine three.",
      )
      expect(page).to have_css(".mod-prompt-preview", wait: 10)
      shot("125_category_prompt_preview_multiline")
    end

    it "shows the audience dropdown set to TL1" do
      visit("/c/#{category.slug}/edit/settings")
      expect(page).to have_css(".mod-new-topic-prompt", wait: 10)
      find(".mod-new-topic-prompt-input").fill_in(with: "A prompt.")
      audience = PageObjects::Components::SelectKit.new(".mod-new-topic-audience-input")
      audience.expand
      audience.select_row_by_value("1")
      shot("126_category_prompt_audience_tl1")
    end

    it "shows the audience dropdown set to TL0" do
      visit("/c/#{category.slug}/edit/settings")
      expect(page).to have_css(".mod-new-topic-prompt", wait: 10)
      find(".mod-new-topic-prompt-input").fill_in(with: "A prompt.")
      audience = PageObjects::Components::SelectKit.new(".mod-new-topic-audience-input")
      audience.expand
      audience.select_row_by_value("0")
      shot("127_category_prompt_audience_tl0")
    end

    it "shows a previously-saved prompt on revisit" do
      category.custom_fields[
        "mod_category_new_topic_prompt"
      ] = "Persisted prompt from a previous save."
      category.custom_fields["mod_category_new_topic_prompt_max_tl"] = 2
      category.save_custom_fields(true)

      visit("/c/#{category.slug}/edit/settings")
      expect(page).to have_css(".mod-new-topic-prompt", wait: 10)
      expect(find(".mod-new-topic-prompt-input").value).to eq(
        "Persisted prompt from a previous save.",
      )
      shot("128_category_prompt_persisted_state")
    end

    it "preview is empty when the field is cleared" do
      visit("/c/#{category.slug}/edit/settings")
      expect(page).to have_css(".mod-new-topic-prompt", wait: 10)
      find(".mod-new-topic-prompt-input").fill_in(with: "")
      shot("129_category_prompt_preview_empty")
    end
  end

  # ---------------------------------------------------------------------------
  # Pin a post to the bottom — extra states
  # ---------------------------------------------------------------------------
  context "pin a post to the bottom — extra states" do
    fab!(:thread_posts) do
      (1..7).map do |i|
        Fabricate(
          :post,
          topic: topic,
          raw: "Reply number #{i} in this thread, long enough to pass.",
        )
      end
    end

    def pin!(target)
      topic.custom_fields["mod_topic_pinned_post_id"] = target.id
      topic.save_custom_fields(true)
    end

    it "shows the bottom-pinned post viewed by a regular user" do
      pin!(thread_posts[2])
      topic.custom_fields["mod_topic_footer_message"] = "Keep replies on-topic only."
      topic.save_custom_fields(true)
      sign_in(user)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".topic-footer-pinned-post", wait: 10)
      shot("130_pinned_post_regular_user_view")
    end

    it "shows the badge on the original in-stream post" do
      pin!(thread_posts[1])
      sign_in(user)
      visit("/t/#{topic.slug}/#{topic.id}/#{thread_posts[1].post_number}")
      expect(page).to have_css(".mod-pinned-in-stream-badge", wait: 10)
      shot("131_pinned_post_in_stream_badge")
    end

    it "shows the pinned bottom post with jump-to-original affordance" do
      pin!(thread_posts[0])
      sign_in(user)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".topic-footer-pinned-post a.pinned-post-jump", wait: 10)
      shot("132_pinned_post_jump_to_original")
    end

    it "shows a topic with a pinned post AND a private note (staff)" do
      pin!(thread_posts[3])
      topic.custom_fields["mod_topic_private_note"] = "Watch this thread — staff only."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.custom_fields["mod_topic_private_note_created_at"] = 1.hour.ago.iso8601
      topic.save_custom_fields(true)
      sign_in(moderator)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".topic-footer-pinned-post", wait: 10)
      expect(page).to have_css(".mod-private-note", wait: 10)
      shot("133_pinned_post_with_private_note")
    end

    it "shows the post admin menu while a post is already pinned" do
      pin!(thread_posts[2])
      sign_in(moderator)
      visit("/t/#{topic.slug}/#{topic.id}/#{thread_posts[2].post_number}")
      within(find("#post_#{thread_posts[2].post_number}")) do
        find(".show-more-actions").click if has_css?(".show-more-actions", wait: 2)
        find(".show-post-admin-menu", match: :first).click
      end
      expect(page).to have_css(".mod-pin-post-to-bottom", wait: 10)
      shot("134_post_admin_menu_while_pinned")
    end

    it "shows a topic with both a pinned post and a footer message together" do
      pin!(thread_posts[4])
      topic.custom_fields[
        "mod_topic_footer_message"
      ] = "Please link uploads — replies must be on-topic."
      topic.save_custom_fields(true)
      sign_in(user)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".topic-footer-pinned-post", wait: 10)
      expect(page).to have_css(".topic-footer-message", wait: 10)
      shot("135_pinned_plus_footer_user_view")
    end
  end

  # ---------------------------------------------------------------------------
  # Per-topic reply approval — extra states
  # ---------------------------------------------------------------------------
  context "per-topic reply approval — extra states" do
    before { sign_in(moderator) }

    it "shows the modal with the approval checkbox unchecked by default" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      open_mod_messages_modal
      expect(find(".mod-require-approval-input")).not_to be_checked
      shot("136_approval_checkbox_unchecked")
    end

    it "shows the approval checkbox ticked then unticked again" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      open_mod_messages_modal
      find(".mod-require-approval-input").click
      expect(find(".mod-require-approval-input")).to be_checked
      shot("137_approval_checkbox_ticked")
      find(".mod-require-approval-input").click
      expect(find(".mod-require-approval-input")).not_to be_checked
      shot("138_approval_checkbox_untoggled")
    end

    it "shows the approval state persisted across a modal reopen" do
      topic.custom_fields["mod_topic_require_reply_approval"] = true
      topic.save_custom_fields(true)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      open_mod_messages_modal
      expect(find(".mod-require-approval-input")).to be_checked
      shot("139_approval_checkbox_persisted")
    end

    it "shows the approval checkbox alongside the footer field" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      open_mod_messages_modal
      find(".mod-footer-input").fill_in(with: "Replies route to mods.")
      find(".mod-require-approval-input").click
      shot("140_approval_with_messages_filled")
    end

    it "renders the topic the same way for a regular user (no extra UI)" do
      topic.custom_fields["mod_topic_require_reply_approval"] = true
      topic.save_custom_fields(true)
      sign_in(user)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      # There is no extra approval UI surfaced to the regular user.
      expect(page).to have_no_css(".mod-require-approval-input")
      shot("141_approval_topic_view_regular_user")
    end
  end

  # ---------------------------------------------------------------------------
  # Private moderator note — extra states
  # ---------------------------------------------------------------------------
  context "private moderator note — extra states" do
    before { sign_in(moderator) }

    it "shows the note positioned at the top of the topic" do
      topic.custom_fields["mod_topic_private_note"] = "Note above the original post."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.custom_fields["mod_topic_private_note_position"] = "top"
      topic.custom_fields["mod_topic_private_note_created_at"] = 1.hour.ago.iso8601
      topic.save_custom_fields(true)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-private-note", wait: 10)
      shot("142_private_note_position_top")
    end

    it "shows the note positioned at the bottom of the topic" do
      topic.custom_fields["mod_topic_private_note"] = "Note below the original post."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.custom_fields["mod_topic_private_note_position"] = "bottom"
      topic.custom_fields["mod_topic_private_note_created_at"] = 1.hour.ago.iso8601
      topic.save_custom_fields(true)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-private-note", wait: 10)
      shot("143_private_note_position_bottom")
    end

    it "shows a long note thread with multiple staff replies" do
      topic.custom_fields["mod_topic_private_note"] = "Initial moderator note for triage."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.custom_fields["mod_topic_private_note_created_at"] = 4.hours.ago.iso8601
      topic.custom_fields["mod_topic_private_note_replies"] = [
        {
          "id" => "aaaaaaaaaaaa0001",
          "user_id" => moderator.id,
          "raw" => "I've sent the user a DM.",
          "created_at" => 3.hours.ago.iso8601,
        },
        {
          "id" => "aaaaaaaaaaaa0002",
          "user_id" => other_moderator.id,
          "raw" => "Thanks — I'll watch the next reply.",
          "created_at" => 2.hours.ago.iso8601,
        },
        {
          "id" => "aaaaaaaaaaaa0003",
          "user_id" => moderator.id,
          "raw" => "Closing the loop — resolved.",
          "created_at" => 1.hour.ago.iso8601,
        },
      ]
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-private-note-reply", count: 3, wait: 10)
      shot("144_private_note_three_replies_thread")
    end

    it "shows the edit and delete affordances on a note reply" do
      topic.custom_fields["mod_topic_private_note"] = "Initial note."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.custom_fields["mod_topic_private_note_created_at"] = 2.hours.ago.iso8601
      topic.custom_fields["mod_topic_private_note_replies"] = [
        {
          "id" => "bbbbbbbbbbbb0001",
          "user_id" => moderator.id,
          "raw" => "A reply with edit/delete buttons visible.",
          "created_at" => 1.hour.ago.iso8601,
        },
      ]
      topic.save_custom_fields(true)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-private-note-reply", wait: 10)
      shot("145_private_note_reply_edit_delete_affordances")
    end

    it "shows the reply composer open with text being entered" do
      topic.custom_fields["mod_topic_private_note"] = "A note to follow up on."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.custom_fields["mod_topic_private_note_created_at"] = 2.hours.ago.iso8601
      topic.save_custom_fields(true)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-private-note", wait: 10)
      find(".mod-private-note-reply-button").click
      find(".mod-private-note-reply-input").fill_in(with: "Drafting a follow-up reply right now.")
      shot("146_private_note_reply_composer_drafting")
    end

    it "the regular user never sees the private note (no DOM node)" do
      topic.custom_fields["mod_topic_private_note"] = "Staff eyes only."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.save_custom_fields(true)
      sign_in(user)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      expect(page).to have_no_css(".mod-private-note")
      shot("147_private_note_user_no_node")
    end

    it "a non-staff TL1 user never sees the private note" do
      topic.custom_fields["mod_topic_private_note"] = "Staff eyes only."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.save_custom_fields(true)
      sign_in(tl1_user)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      expect(page).to have_no_css(".mod-private-note")
      shot("148_private_note_non_staff_view")
    end
  end

  # ---------------------------------------------------------------------------
  # Moderator-notes user-menu tab — extra states
  # ---------------------------------------------------------------------------
  context "moderator-notes user-menu tab — extra states" do
    fab!(:second_topic) do
      Fabricate(:topic, category: category, title: "A second thread to review")
    end
    fab!(:second_post) do
      Fabricate(:post, topic: second_topic, raw: "Original post in thread two.")
    end
    fab!(:third_topic) do
      Fabricate(:topic, category: category, title: "A third thread under review")
    end
    fab!(:third_post) do
      Fabricate(:post, topic: third_topic, raw: "Original post in thread three.")
    end

    before do
      [topic, second_topic, third_topic].each_with_index do |t, i|
        t.custom_fields["mod_topic_private_note"] = "Note number #{i + 1} — needs eyes."
        t.custom_fields["mod_topic_private_note_user_id"] = moderator.id
        t.custom_fields["mod_topic_private_note_activity_at"] = (i + 1).hours.ago.iso8601
        t.custom_fields["mod_topic_private_note_created_at"] = (i + 1).hours.ago.iso8601
        t.save_custom_fields(true)
      end
      sign_in(other_moderator)
    end

    it "shows the user menu with the shield tab and an unread badge" do
      visit("/")
      find(".header-dropdown-toggle.current-user").click
      expect(page).to have_css("#user-menu-button-discourse-mod-notes", wait: 10)
      shot("149_user_menu_shield_tab_with_unread")
    end

    it "shows the notes panel listing multiple notes" do
      visit("/")
      find(".header-dropdown-toggle.current-user").click
      find("#user-menu-button-discourse-mod-notes").click
      expect(page).to have_css(".mod-notes-panel .mod-notes-item", wait: 10)
      shot("150_notes_panel_multiple_entries")
    end

    it "shows the notes panel scrolled to a single note" do
      # Trim back to one note for a single-entry panel state.
      [second_topic, third_topic].each do |t|
        t.custom_fields["mod_topic_private_note"] = ""
        t.save_custom_fields(true)
      end

      visit("/")
      find(".header-dropdown-toggle.current-user").click
      find("#user-menu-button-discourse-mod-notes").click
      expect(page).to have_css(".mod-notes-panel .mod-notes-item", wait: 10)
      shot("151_notes_panel_single_entry")
    end

    it "shows the moderator-notes panel after the seen marker is recorded" do
      other_moderator.upsert_custom_fields("mod_notes_seen_at" => Time.zone.now.iso8601)
      visit("/")
      find(".header-dropdown-toggle.current-user").click
      find("#user-menu-button-discourse-mod-notes").click
      expect(page).to have_css(".mod-notes-panel .mod-notes-item", wait: 10)
      shot("152_notes_panel_after_seen")
    end

    it "shows the empty-state when there are no moderator notes" do
      [topic, second_topic, third_topic].each do |t|
        t.custom_fields["mod_topic_private_note"] = ""
        t.save_custom_fields(true)
      end
      visit("/")
      find(".header-dropdown-toggle.current-user").click
      find("#user-menu-button-discourse-mod-notes").click
      shot("153_notes_panel_empty_state")
    end

    it "clicking a note entry navigates to its topic" do
      visit("/")
      find(".header-dropdown-toggle.current-user").click
      find("#user-menu-button-discourse-mod-notes").click
      expect(page).to have_css(".mod-notes-panel .mod-notes-item", wait: 10)
      first(".mod-notes-panel .mod-notes-item a").click
      expect(page).to have_css("#topic-title", wait: 10)
      shot("154_notes_panel_link_navigated")
    end
  end

  # ---------------------------------------------------------------------------
  # First-post checklist — extra states
  # ---------------------------------------------------------------------------
  context "first-post checklist — extra states" do
    def set_checklist(version:, max_tl: 2, button_label: "I agree, post", items: nil)
      items ||= [
        { "label" => "I read the community guidelines", "url" => "https://example.com/guidelines" },
        { "label" => "This is an app upload", "url" => "" },
      ]
      PluginStore.set(
        NS,
        KEY,
        {
          "version" => version,
          "max_tl" => max_tl,
          "button_label" => button_label,
          "updated_at" => Time.zone.now.iso8601,
          "items" => items,
        },
      )
    end

    def open_checklist_modal
      visit("/")
      find("[data-list-item-name='mod-checklist']", wait: 10).click
      expect(page).to have_css(".mod-checklist-modal", wait: 10)
    end

    it "shows an empty editor when no checklist exists" do
      sign_in(moderator)
      open_checklist_modal
      expect(page).to have_css(".mod-checklist-add-inline", wait: 10)
      expect(page).to have_no_css(".mod-checklist-row")
      shot("155_checklist_editor_inactive_notice")
    end

    it "shows the checklist editor with a custom button label" do
      set_checklist(version: 1, max_tl: 2, button_label: "Yes — post my reply")
      sign_in(moderator)
      open_checklist_modal
      expect(page).to have_css(".mod-checklist-row", wait: 10)
      expect(find(".mod-checklist-button-label").value).to eq("Yes — post my reply")
      shot("156_checklist_editor_custom_button_label")
    end

    it "shows the audience set to 'Up to basic (TL0 to TL1)' in the editor" do
      set_checklist(version: 1, max_tl: 1)
      sign_in(moderator)
      open_checklist_modal
      expect(page).to have_css(".mod-checklist-row", wait: 10)
      shot("157_checklist_editor_audience_tl1")
    end

    it "shows the 'Last updated' line on the user-facing modal" do
      set_checklist(version: 1, max_tl: 2)
      sign_in(tl1_user)
      visit(topic.url)
      find("#topic-footer-buttons .create", match: :first).click
      find(".d-editor-input").fill_in(with: "Here is my first reply.")
      find(".save-or-cancel .create").click
      expect(page).to have_css(".mod-first-post-checklist-modal", wait: 10)
      expect(page).to have_css(".mod-checklist-updated-at", wait: 10)
      shot("158_checklist_user_modal_last_updated")
    end

    it "shows the checklist's custom button label on the user-facing modal" do
      set_checklist(version: 1, max_tl: 2, button_label: "I agree — post my reply")
      sign_in(tl1_user)
      visit(topic.url)
      find("#topic-footer-buttons .create", match: :first).click
      find(".d-editor-input").fill_in(with: "Here is my first reply.")
      find(".save-or-cancel .create").click
      expect(page).to have_css(".mod-first-post-checklist-modal", wait: 10)
      expect(page).to have_css(".mod-checklist-confirm", text: "I agree — post my reply", wait: 10)
      shot("159_checklist_user_modal_custom_button")
    end

    it "shows a populated audit log with mixed versions" do
      set_checklist(version: 3, max_tl: 2)
      PluginStore.set(
        NS,
        LOG_KEY,
        [
          { "user_id" => tl0_user.id, "version" => 1, "at" => 3.days.ago.iso8601 },
          { "user_id" => tl1_user.id, "version" => 1, "at" => 2.days.ago.iso8601 },
          { "user_id" => tl0_user.id, "version" => 2, "at" => 1.day.ago.iso8601 },
          { "user_id" => tl1_user.id, "version" => 2, "at" => 12.hours.ago.iso8601 },
          { "user_id" => user.id, "version" => 3, "at" => 30.minutes.ago.iso8601 },
        ],
      )
      sign_in(moderator)
      open_checklist_modal
      expect(page).to have_css(".mod-checklist-log-table tbody tr", count: 5, wait: 10)
      shot("160_checklist_audit_log_many_entries")
    end

    it "shows the targeted checklist editor open with a populated row" do
      set_checklist(version: 1, max_tl: 2)
      PluginStore.set(
        NS,
        TARGETED_KEY,
        [
          {
            "id" => "tar-001",
            "name" => "App uploaders",
            "user_ids" => [user.id],
            "version" => 1,
            "updated_at" => Time.zone.now.iso8601,
            "button_label" => "I agree, post",
            "items" => [{ "label" => "I read the upload rules", "url" => "" }],
          },
        ],
      )
      sign_in(moderator)
      open_checklist_modal
      expect(page).to have_css(".mod-checklist-row", wait: 10)
      shot("161_targeted_checklist_listed")
    end

    it "shows a TL2 user prompted under a TL0-TL2 cap" do
      tl2 = Fabricate(:user, trust_level: TrustLevel[2], refresh_auto_groups: true)
      set_checklist(version: 1, max_tl: 2)
      sign_in(tl2)
      visit(topic.url)
      find("#topic-footer-buttons .create", match: :first).click
      find(".d-editor-input").fill_in(with: "First reply at TL2.")
      find(".save-or-cancel .create").click
      expect(page).to have_css(".mod-first-post-checklist-modal", wait: 10)
      shot("162_checklist_tl2_user_prompted")
    end
  end

  # ---------------------------------------------------------------------------
  # Moderator whisper — extra states
  # ---------------------------------------------------------------------------
  context "moderator whisper — extra states" do
    fab!(:target_one) { Fabricate(:user, username: "target_tom") }
    fab!(:target_two) { Fabricate(:user, username: "target_tina") }
    fab!(:target_three) { Fabricate(:user, username: "target_tara") }
    fab!(:stranger) { Fabricate(:user, username: "stranger_sam") }

    def make_whisper(targets:, groups: [], raw: "A whisper.")
      whisper = Fabricate(:post, topic: topic, user: moderator, raw: raw)
      whisper.custom_fields[TARGETS_FIELD] = targets.map(&:id)
      whisper.custom_fields[TARGET_GROUPS_FIELD] = groups.map(&:id) if groups.any?
      whisper.save_custom_fields(true)
      non_staff_ids = targets.reject { |u| u.staff? }.map(&:id)
      if non_staff_ids.any?
        topic.custom_fields[PARTICIPANTS_FIELD] = non_staff_ids
        topic.save_custom_fields(true)
      end
      whisper
    end

    it "shows the whisper banner with a single target" do
      make_whisper(targets: [target_one])
      sign_in(moderator)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-whisper-banner", wait: 15)
      shot("163_whisper_banner_one_target")
    end

    it "shows the whisper banner with three targets" do
      make_whisper(targets: [target_one, target_two, target_three])
      sign_in(moderator)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-whisper-banner", wait: 15)
      shot("164_whisper_banner_three_targets")
    end

    it "shows a staff-only whisper banner (no user targets)" do
      whisper = Fabricate(:post, topic: topic, user: moderator, raw: "Staff only.")
      whisper.custom_fields[TARGETS_FIELD] = []
      whisper.save_custom_fields(true)
      sign_in(moderator)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-whisper-banner", wait: 15)
      shot("165_whisper_banner_staff_only")
    end

    it "shows a group-targeted whisper banner" do
      group = Fabricate(:group, name: "whisper_squad")
      group.add(target_one)
      make_whisper(targets: [], groups: [group])
      sign_in(moderator)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-whisper-banner", wait: 15)
      shot("166_whisper_banner_group_target")
    end

    it "shows the armed-whisper pill with a single user" do
      sign_in(moderator)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      find("#topic-footer-buttons .create", match: :first).click
      expect(page).to have_css(".d-editor-input", wait: 10)
      button_selector =
        ".d-editor-button-bar button.mod-whisper-target, " \
          ".d-editor-button-bar button[title='#{
            I18n.t("js.discourse_mod_categories.whisper.toolbar_title")
          }']"
      find(button_selector, match: :first).click
      expect(page).to have_css(".mod-whisper-target-modal", wait: 10)
      chooser =
        PageObjects::Components::SelectKit.new(
          ".mod-whisper-target-modal .email-group-user-chooser",
        )
      chooser.expand
      chooser.search(target_one.username)
      chooser.select_row_by_value(target_one.username)
      chooser.collapse
      find(".mod-whisper-target-modal .mod-whisper-confirm").click
      expect(page).to have_css(".mod-whisper-armed-pill", wait: 10)
      shot("167_armed_whisper_pill_single_user")
    end

    it "shows the add-participant modal with a chosen user" do
      make_whisper(targets: [target_one])
      sign_in(admin)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-whisper-banner", wait: 15)

      within("#post_#{topic.reload.posts.last.post_number}") do
        if has_css?(".post-controls .show-more-actions", wait: 2)
          find(".post-controls .show-more-actions").click
        end
        find(".post-controls .show-post-admin-menu").click
      end
      expect(page).to have_css(".mod-whisper-add-participant", wait: 10)
      find(".mod-whisper-add-participant").click
      expect(page).to have_css(".mod-whisper-add-participant-modal", wait: 10)
      chooser =
        PageObjects::Components::SelectKit.new(
          ".mod-whisper-add-participant-modal .email-group-user-chooser",
        )
      chooser.expand
      chooser.search(stranger.username)
      chooser.select_row_by_value(stranger.username)
      chooser.collapse
      shot("168_whisper_add_participant_modal_user_chosen")
    end

    it "shows a non-participant viewing the topic with no whisper visible" do
      make_whisper(targets: [target_one])
      sign_in(stranger)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      expect(page).to have_no_css(".mod-whisper-banner")
      shot("169_whisper_non_participant_view")
    end

    it "shows a recipient's view with the whisper banner visible" do
      make_whisper(targets: [target_one])
      sign_in(target_one)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-whisper-banner", wait: 15)
      shot("170_whisper_recipient_full_view")
    end
  end
end
