# frozen_string_literal: true

require "rails_helper"

# End-to-end coverage for the moderator whisper feature: arming a whisper
# from the composer, the target modal, posting, audience visibility, and the
# non-participant gate. A screenshot is captured at each meaningful step;
# screenshots land in tmp/capybara/ and are published as the CI artifact.
RSpec.describe "Moderator whisper" do
  fab!(:moderator) { Fabricate(:moderator, username: "mod_morgan") }
  fab!(:admin) { Fabricate(:admin, username: "admin_ada") }
  fab!(:recipient) { Fabricate(:user, username: "target_tom") }
  fab!(:other_target) { Fabricate(:user, username: "target_tina") }
  fab!(:stranger) { Fabricate(:user, username: "stranger_sam") }
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category, title: "A thread to whisper in") }
  fab!(:op) { Fabricate(:post, topic: topic, raw: "The original post here.") }
  fab!(:group_member) { Fabricate(:user, username: "group_gabe") }
  fab!(:whisper_group) { Fabricate(:group, name: "whisper_squad") }

  let(:targets_field) { DiscourseModCategories::POST_WHISPER_TARGETS_FIELD }
  let(:groups_field) { DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD }
  let(:participants_field) { DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD }

  before do
    # `mod_categories_enabled` is the plugin's master switch — the whole
    # plugin's frontend assets only load when it is on.
    SiteSetting.mod_categories_enabled = true
    SiteSetting.mod_whisper_enabled = true
    SiteSetting.min_post_length = 5
    SiteSetting.body_min_entropy = 1
    SiteSetting.auto_silence_fast_typers_on_first_post = false
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

  def open_reply_composer
    find("#topic-footer-buttons .create", match: :first).click
    expect(page).to have_css(".d-editor-input", wait: 10)
  end

  def whisper_button_selector
    ".d-editor-button-bar button.mod-whisper-target, " \
      ".d-editor-button-bar button[title='#{
        I18n.t("js.discourse_mod_categories.whisper.toolbar_title")
      }']"
  end

  def whisper_toolbar_button
    find(whisper_button_selector, match: :first)
  end

  def make_whisper_post(targets, raw: "A staff whisper for the audience.")
    whisper = Fabricate(:post, topic: topic, user: moderator, raw: raw)
    whisper.custom_fields[targets_field] = targets
    whisper.save_custom_fields(true)
    non_staff = User.where(id: targets).where(admin: false, moderator: false)
    if non_staff.any?
      topic.custom_fields[participants_field] = non_staff.pluck(:id)
      topic.save_custom_fields(true)
    end
    whisper
  end

  def make_group_whisper_post(group_ids, raw: "A staff whisper for a group.")
    whisper = Fabricate(:post, topic: topic, user: moderator, raw: raw)
    whisper.custom_fields[targets_field] = []
    whisper.custom_fields[groups_field] = group_ids
    whisper.save_custom_fields(true)
    whisper
  end

  context "a staff whisper targeted at a group" do
    before do
      whisper_group.add(group_member)
      make_group_whisper_post([whisper_group.id])
    end

    it "renders the group in the whisper banner" do
      sign_in(moderator)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".cooked.mod-whisper .mod-whisper-banner", wait: 15)
      expect(page).to have_css(
        ".mod-whisper-banner .mod-whisper-banner__group",
        exact_text: "@#{whisper_group.name}",
        wait: 15,
      )
      shot("76_group_whisper_banner")
    end

    it "shows the whisper to a member of the target group" do
      sign_in(group_member)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".cooked.mod-whisper .mod-whisper-banner", wait: 15)
      shot("77_group_member_sees_whisper")
    end

    it "hides the whisper from a non-member non-staff user" do
      sign_in(stranger)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      expect(page).to have_no_css(".mod-whisper-banner")
      shot("78_non_member_does_not_see_group_whisper")
    end
  end

  context "a moderator arms a whisper from the composer" do
    before { sign_in(moderator) }

    it "shows the eye button, opens the modal and arms the pill" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      open_reply_composer
      expect(page).to have_css(whisper_button_selector, wait: 10)
      shot("62_composer_whisper_button")

      whisper_toolbar_button.click
      expect(page).to have_css(".mod-whisper-target-modal", wait: 10)
      expect(page).to have_css(".mod-whisper-target-modal .email-group-user-chooser")
      shot("63_whisper_target_modal_empty")

      chooser =
        PageObjects::Components::SelectKit.new(
          ".mod-whisper-target-modal .email-group-user-chooser",
        )
      chooser.expand
      chooser.search(recipient.username)
      chooser.select_row_by_value(recipient.username)
      chooser.search(other_target.username)
      chooser.select_row_by_value(other_target.username)
      shot("64_whisper_target_modal_users_selected")

      chooser.collapse
      find(".mod-whisper-target-modal .mod-whisper-confirm").click
      expect(page).to have_no_css(".mod-whisper-target-modal", wait: 10)

      expect(page).to have_css(".mod-whisper-armed-pill", wait: 10)
      expect(page).to have_css(".mod-whisper-armed-pill__user", text: "@#{recipient.username}")
      shot("65_whisper_armed_pill")

      find(".d-editor-input").fill_in(with: "A private aside for the two of you.")
      find(".save-or-cancel .create").click

      expect(page).to have_css(
        ".cooked.mod-whisper.mod-whisper--staff .mod-whisper-banner",
        wait: 15,
      )
      shot("66_staff_whisper_posted_banner")

      whisper_post = topic.reload.posts.last
      expect(whisper_post.custom_fields[targets_field].map(&:to_i)).to(
        match_array([recipient.id, other_target.id]),
      )
    end
  end

  context "a moderator arms a staff-only whisper (no targets)" do
    before { sign_in(moderator) }

    # Regression: confirming the target modal with NO users selected arms a
    # staff-only whisper. It must post as a whisper, not a public post.
    it "posts a staff-only whisper and renders the staff banner" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      open_reply_composer
      expect(page).to have_css(whisper_button_selector, wait: 10)

      whisper_toolbar_button.click
      expect(page).to have_css(".mod-whisper-target-modal", wait: 10)
      # Confirm with an empty selection — a staff-only whisper.
      find(".mod-whisper-target-modal .mod-whisper-confirm").click
      expect(page).to have_no_css(".mod-whisper-target-modal", wait: 10)

      expect(page).to have_css(".mod-whisper-armed-pill", wait: 10)
      expect(page).to have_css(
        ".mod-whisper-armed-pill__label",
        text: I18n.t("js.discourse_mod_categories.whisper.armed_pill_staff_only"),
      )
      shot("65b_staff_only_whisper_armed")

      find(".d-editor-input").fill_in(with: "A note just for the staff team.")
      find(".save-or-cancel .create").click

      # The banner survives the post stream inside .cooked.
      expect(page).to have_css(".cooked.mod-whisper .mod-whisper-banner", wait: 15)
      expect(page).to have_css(
        ".cooked .mod-whisper-banner",
        text: I18n.t("js.discourse_mod_categories.whisper.banner_to_staff"),
        wait: 15,
      )
      shot("65c_staff_only_whisper_posted_banner")

      whisper_post = topic.reload.posts.last
      expect(whisper_post.custom_fields.key?(targets_field)).to eq(true)
      expect(whisper_post.custom_fields[targets_field]).to eq([])
    end
  end

  context "replying to a whisper auto-arms a whisper-back" do
    let!(:whisper) { make_whisper_post([recipient.id]) }

    # Opening the composer to reply to a whisper auto-arms a whisper-back by
    # default — the `composer:opened` handler sets modWhisperArmed and the
    # target props, so the armed pill appears without any extra click.
    # NOTE: quote-reply behaviour is intentionally unchanged and not covered.
    it "shows the armed pill when replying to a whisper" do
      sign_in(admin)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-whisper-banner", wait: 15)

      # Reply directly to the whisper post (article#post_<n>).
      within("#post_#{whisper.post_number}") { find(".post-controls button.reply").click }
      expect(page).to have_css(".d-editor-input", wait: 10)

      expect(page).to have_css(".mod-whisper-armed-pill", wait: 10)
      shot("75_reply_to_whisper_auto_armed")
    end
  end

  context "audience visibility of a posted whisper" do
    before { make_whisper_post([recipient.id]) }

    it "lets the recipient see the whisper banner" do
      sign_in(recipient)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".cooked.mod-whisper .mod-whisper-banner", wait: 15)
      shot("67_recipient_sees_whisper")
    end

    it "does NOT show the whisper to a stranger" do
      sign_in(stranger)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      expect(page).to have_no_css(".mod-whisper-banner")
      shot("68_stranger_does_not_see_whisper")
    end

    it "shows the whisper to a staff member for oversight" do
      sign_in(admin)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".cooked.mod-whisper .mod-whisper-banner", wait: 15)
      shot("69_staff_oversight")
    end
  end

  context "a topic participant whispers back" do
    before { make_whisper_post([recipient.id]) }

    it "does NOT show the whisper toolbar button to a non-staff participant" do
      # Previously the participant could click the eye button to arm a
      # staff-only whisper-back from the topic-level reply composer.
      # That UI was removed: whisper-arming is staff-only at the toolbar
      # level. Non-staff who hit Reply directly on a whisper POST still
      # get their reply auto-armed by the `composer:opened` handler in
      # mod-whisper.js — they just don't get a manual toggle from the
      # topic-level reply composer.
      sign_in(recipient)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-whisper-banner", wait: 15)

      open_reply_composer
      expect(page).to have_css(".d-editor-input", wait: 10)
      expect(page).to have_no_css(".d-editor-button-bar button.mod-whisper-target")
      shot("70_participant_no_whisper_button")
    end
  end

  context "a non-participant user" do
    before { make_whisper_post([recipient.id]) }

    it "does NOT show the whisper toolbar button to a non-participant" do
      sign_in(stranger)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      open_reply_composer
      expect(page).to have_css(".d-editor-input", wait: 10)
      expect(page).to have_no_css(".d-editor-button-bar button.mod-whisper-target")
      shot("72_non_participant_no_whisper_button")
    end
  end

  context "the site setting" do
    before { sign_in(admin) }

    it "exposes the mod_whisper_enabled setting in the admin UI" do
      visit("/admin/site_settings/category/all_results?filter=mod_whisper")
      expect(page).to have_css(".admin-detail .setting", wait: 10)
      shot("73_site_setting_page")
    end
  end

  context "staff add a user to a whisper" do
    let!(:whisper) { make_whisper_post([recipient.id]) }

    it "adds a user via the whisper post admin menu" do
      sign_in(admin)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-whisper-banner", wait: 15)

      # Open the post admin (wrench) menu on the whisper post.
      within("#post_#{topic.reload.posts.last.post_number}") do
        if page.has_css?(".post-controls .show-more-actions")
          find(".post-controls .show-more-actions").click
        end
        find(".post-controls .show-post-admin-menu").click
      end
      expect(page).to have_css(".mod-whisper-add-participant", wait: 10)
      shot("79_whisper_post_admin_menu")

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
      shot("80_whisper_add_participant_modal")

      find(".mod-whisper-add-participant-confirm").click
      expect(page).to have_no_css(".mod-whisper-add-participant-modal", wait: 10)
      shot("81_whisper_participant_added")

      expect(Array(whisper.reload.custom_fields[targets_field]).map(&:to_i)).to include(stranger.id)
    end
  end

  context "with the plugin disabled" do
    before do
      make_whisper_post([recipient.id])
      SiteSetting.mod_whisper_enabled = false
    end

    it "keeps existing whispers private" do
      sign_in(stranger)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      # Switching the feature off stops new whispers; it never publishes
      # the existing ones.
      expect(page).to have_css(".topic-post", count: 1, wait: 10)
      expect(page).to have_no_content("A staff whisper for the audience.")
      shot("74_plugin_disabled_still_private")
    end
  end
end
