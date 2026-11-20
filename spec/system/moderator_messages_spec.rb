# frozen_string_literal: true

require "rails_helper"

# End-to-end coverage for the moderator-set messages, capturing a
# screenshot at every meaningful UI step. Screenshots are written to
# tmp/capybara/ and published as the CI artifact.
RSpec.describe "Moderator messages" do
  fab!(:admin)
  fab!(:moderator)
  fab!(:user)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category, title: "Share your app build here") }
  fab!(:post) { Fabricate(:post, topic: topic, raw: "Drop your app uploads in this thread.") }

  let(:reply_warning) do
    "Is this an app upload or link to an app? If it's just a comment or " \
      "question, please post somewhere else."
  end
  let(:footer_text) { "This thread is for app uploads only — keep replies on-topic." }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.topic_footer_message_enabled = true
    SiteSetting.topic_reply_prompt_enabled = true
    SiteSetting.precheck_new_topic_enabled = true
    SiteSetting.min_post_length = 5
    SiteSetting.body_min_entropy = 1
  end

  def shot(name)
    # Wait for images (avatars) to finish loading so screenshots are not
    # captured mid-load.
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
  end

  context "a moderator sets the per-topic messages via the admin menu" do
    before { sign_in(moderator) }

    it "walks through opening the menu, the modal, saving, and rendering" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      shot("01_topic_page_moderator")

      open_admin_menu
      expect(page).to have_css(".mod-topic-messages-button", wait: 10)
      shot("02_topic_admin_menu_open")

      find(".mod-topic-messages-button").click
      expect(page).to have_css(".mod-topic-messages-modal", wait: 10)
      shot("03_mod_messages_modal_empty")

      find(".mod-topic-messages-modal .mod-footer-input").fill_in(with: footer_text)
      shot("04_mod_messages_footer_filled")

      # The before-reply prompt has moved to the Prompt Checklist modal;
      # this modal no longer carries it.
      expect(page).to have_no_css(".mod-topic-messages-modal .mod-reply-input")
      expect(page).to have_no_css(".mod-topic-messages-modal .mod-reply-audience-input")
      shot("05_mod_messages_both_filled")

      find(".mod-topic-messages-modal .mod-messages-save").click
      expect(page).to have_no_css(".mod-topic-messages-modal", wait: 10)

      expect(page).to have_css(
        ".topic-footer-message",
        text: "This thread is for app uploads only",
        wait: 10,
      )
      shot("06_footer_rendered_after_save")

      expect(topic.custom_fields["mod_topic_footer_message"]).to eq(footer_text)
    end

    it "shows both modal sections — the reply prompt is no longer here" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      open_mod_messages_modal
      expect(page).to have_css(".mod-topic-messages-modal", wait: 10)
      # The modal is split into a "visible to everyone" section and a
      # "moderation" section.
      expect(page).to have_css(".mod-messages-section", minimum: 2)
      shot("80_mod_messages_modal_sections")

      # The before-reply prompt + audience dropdown have moved out of
      # this modal entirely; staff configure both under Prompt Checklist.
      expect(page).to have_no_css(".mod-reply-input")
      expect(page).to have_no_css(".mod-reply-audience-input")

      find(".mod-require-approval-input").click
      find(".mod-messages-save").click
      # A success toast confirms the save.
      expect(page).to have_css(".fk-d-default-toast", wait: 10)
      shot("82_mod_messages_save_toast")
    end

    it "re-opens the modal pre-filled for editing and updates the values" do
      topic.custom_fields["mod_topic_footer_message"] = "An existing footer"
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      shot("07_topic_with_existing_footer")

      open_mod_messages_modal
      expect(page).to have_css(".mod-topic-messages-modal", wait: 10)
      expect(find(".mod-footer-input").value).to eq("An existing footer")
      shot("08_mod_messages_modal_editing")

      find(".mod-footer-input").fill_in(with: "Updated footer notice")
      shot("09_mod_messages_modal_edited")

      find(".mod-messages-save").click
      expect(page).to have_css(".topic-footer-message", text: "Updated footer notice", wait: 10)
      shot("10_footer_updated_after_edit")
    end

    it "can clear the messages by saving blank fields" do
      topic.custom_fields["mod_topic_footer_message"] = footer_text
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".topic-footer-message", wait: 10)
      shot("11_footer_before_clearing")

      open_mod_messages_modal
      find(".mod-footer-input").fill_in(with: "")
      shot("12_mod_messages_modal_cleared")
      find(".mod-messages-save").click

      expect(page).to have_no_css(".topic-footer-message", wait: 10)
      shot("13_footer_removed_after_clearing")
    end

    it "can require reply approval for the topic from the modal" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      open_mod_messages_modal
      expect(page).to have_css(".mod-topic-messages-modal", wait: 10)

      find(".mod-require-approval-input").click
      shot("38_mod_messages_require_approval_checked")

      find(".mod-messages-save").click
      expect(page).to have_no_css(".mod-topic-messages-modal", wait: 10)
      expect(topic.reload.custom_fields["mod_topic_require_reply_approval"]).to eq(true)
    end

    it "sets a staff-only private note from the modal and shows it" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      open_mod_messages_modal
      expect(page).to have_css(".mod-topic-messages-modal", wait: 10)

      find(".mod-private-note-input").fill_in(with: "Keep an eye on this thread — staff only.")
      find(".mod-messages-save").click
      expect(page).to have_no_css(".mod-topic-messages-modal", wait: 10)

      expect(page).to have_css(".mod-private-note", text: "Keep an eye on this thread", wait: 10)
      # Shown like a post — the moderator who set it, with avatar + name.
      expect(page).to have_css(
        ".mod-private-note .mod-private-note-username",
        text: moderator.name.presence || moderator.username,
      )
      expect(page).to have_css(".mod-private-note .mod-private-note-avatar")
      shot("40_private_note_staff_view")
    end

    it "lets a moderator reply to the note thread" do
      topic.custom_fields["mod_topic_private_note"] = "Initial moderator note."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.custom_fields["mod_topic_private_note_created_at"] = 2.hours.ago.iso8601
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-private-note", wait: 10)
      # The note shows a relative timestamp and a reply button.
      expect(page).to have_css(".mod-private-note .mod-private-note-time")
      expect(page).to have_css(".mod-private-note-reply-button")
      shot("46_private_note_with_timestamp_and_reply_button")

      find(".mod-private-note-reply-button").click
      find(".mod-private-note-reply-input").fill_in(with: "Thanks — I'll keep an eye on this.")
      shot("47_private_note_reply_box")

      find(".mod-private-note-reply-box .btn-primary").click
      # The reply body is cooked as markdown, so straight quotes become
      # typographic — match a fragment without an apostrophe.
      expect(page).to have_css(".mod-private-note-reply", text: "keep an eye on this", wait: 10)
      shot("48_private_note_reply_added")
      expect(topic.reload.custom_fields["mod_topic_private_note_replies"]).to be_present
    end

    it "lets a moderator edit and delete a reply in the note thread" do
      topic.custom_fields["mod_topic_private_note"] = "Initial moderator note."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.custom_fields["mod_topic_private_note_created_at"] = 2.hours.ago.iso8601
      topic.custom_fields["mod_topic_private_note_replies"] = [
        {
          "id" => "aaaaaaaaaaaaaaaa",
          "user_id" => moderator.id,
          "raw" => "Original reply text.",
          "created_at" => 1.hour.ago.iso8601,
        },
      ]
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".mod-private-note-reply", wait: 10)

      # Edit the reply inline.
      find(".mod-private-note-reply .mod-private-note-edit-reply").click
      find(".mod-private-note-edit-input").fill_in(with: "Updated reply text.")
      shot("92_private_note_reply_editing")
      find(".mod-private-note-reply-box .btn-primary").click
      expect(page).to have_css(".mod-private-note-reply", text: "Updated reply text", wait: 10)
      shot("93_private_note_reply_edited")
      expect(topic.reload.custom_fields["mod_topic_private_note_replies"].first["raw"]).to eq(
        "Updated reply text.",
      )

      # Delete the reply (confirm via the dialog).
      find(".mod-private-note-reply .mod-private-note-delete-reply").click
      find(".dialog-footer .btn-primary").click
      expect(page).to have_no_css(".mod-private-note-reply", wait: 10)
      shot("94_private_note_reply_deleted")
      expect(topic.reload.custom_fields["mod_topic_private_note_replies"]).to eq([])
    end
  end

  context "the reply prompt fires for a user" do
    before do
      topic.custom_fields["mod_topic_reply_prompt"] = reply_warning
      topic.save_custom_fields(true)
      sign_in(user)
    end

    it "warns the user, supports Go back, and supports Post anyway" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      shot("14_user_views_topic")

      find("#topic-footer-buttons .create", match: :first).click
      find(".d-editor-input").fill_in(with: "Here is a reply to this topic.")
      shot("15_user_reply_composer")

      find(".save-or-cancel .create").click
      expect(page).to have_css(
        ".dialog-body",
        text: "Is this an app upload or link to an app?",
        wait: 10,
      )
      shot("16_reply_prompt_dialog")

      find(".dialog-footer button", text: "Go back").click
      expect(page).to have_css(".d-editor-input")
      shot("17_reply_prompt_go_back")

      find(".save-or-cancel .create").click
      expect(page).to have_css(".dialog-body", wait: 10)
      find(".dialog-footer button", text: "Post anyway").click
      expect(page).to have_no_css(".dialog-body", wait: 10)
      shot("18_reply_prompt_post_anyway")
    end

    it "does not show the admin menu or mod-messages button to a regular user" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      expect(page).to have_no_css(".toggle-admin-menu")
      expect(page).to have_no_css(".mod-topic-messages-button")
      shot("19_regular_user_no_mod_button")
    end
  end

  context "the footer message renders for a regular user" do
    before do
      topic.custom_fields["mod_topic_footer_message"] = footer_text
      topic.save_custom_fields(true)
      sign_in(user)
    end

    it "shows the moderator footer at the bottom of the topic" do
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(
        ".topic-footer-message",
        text: "This thread is for app uploads only",
        wait: 10,
      )
      shot("20_footer_visible_to_user")
    end

    it "renders the footer message as HTML" do
      topic.custom_fields[
        "mod_topic_footer_message"
      ] = "<strong>Important:</strong> read the rules."
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".topic-footer-message strong", text: "Important:", wait: 10)
      shot("36_footer_html_rendered")
    end

    it "still shows the footer on a closed topic" do
      topic.update!(closed: true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css(".topic-footer-message", wait: 10)
      shot("37_footer_on_closed_topic")
    end

    it "never shows the staff-only private note to a regular user" do
      topic.custom_fields["mod_topic_private_note"] = "Staff eyes only"
      topic.save_custom_fields(true)

      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)
      expect(page).to have_no_css(".mod-private-note")
      shot("41_private_note_hidden_from_user")
    end
  end

  context "a moderator sets the per-category new-topic prompt" do
    before do
      # Reaching the category settings screen is core's
      # moderators_manage_categories.
      SiteSetting.moderators_manage_categories = true
      sign_in(moderator)
    end

    it "saves the prompt from the category settings screen" do
      visit("/c/#{category.slug}/edit/settings")
      expect(page).to have_css(".mod-new-topic-prompt", wait: 10)
      shot("21_category_settings_prompt_field")

      find(".mod-new-topic-prompt-input").fill_in(
        with: "Please search for an existing topic before starting a new one.",
      )
      shot("22_category_prompt_filled")

      find(".mod-save-new-topic-prompt").click
      expect(page).to have_css(".mod-saved-indicator", wait: 10)
      shot("23_category_prompt_saved")

      expect(category.reload.custom_fields["mod_category_new_topic_prompt"]).to eq(
        "Please search for an existing topic before starting a new one.",
      )
    end

    it "shows a live preview of the new-topic prompt with a clickable link" do
      visit("/c/#{category.slug}/edit/settings")
      expect(page).to have_css(".mod-new-topic-prompt", wait: 10)

      find(".mod-new-topic-prompt-input").fill_in(
        with: "Read the guidelines at https://example.com/guidelines before posting.",
      )
      # The preview renders the typed text the same way the dialog will,
      # turning the URL into a real link.
      expect(page).to have_css(".mod-prompt-preview", wait: 10)
      link = find(".mod-prompt-preview-body a[href='https://example.com/guidelines']")
      expect(link[:target]).to eq("_blank")
      shot("83_category_prompt_live_preview")

      # The audience combo-box caps which trust levels see the prompt.
      audience = PageObjects::Components::SelectKit.new(".mod-new-topic-audience-input")
      audience.expand
      shot("84_category_prompt_audience_dropdown")
      audience.select_row_by_value("2")

      find(".mod-save-new-topic-prompt").click
      expect(page).to have_css(".mod-saved-indicator", wait: 10)
      expect(category.reload.custom_fields["mod_category_new_topic_prompt_max_tl"]).to eq(2)
    end
  end

  context "a moderator pins a post to the bottom" do
    # A long thread (12 posts: the OP + 11 replies) so posts can be pinned
    # at various distances from the end.
    fab!(:thread_posts) do
      (1..11).map do |i|
        Fabricate(
          :post,
          topic: topic,
          raw: "Reply number #{i} in this long thread, long enough to pass.",
        )
      end
    end

    let(:last_post) { thread_posts[10] } # post 12
    let(:second_to_last) { thread_posts[9] } # post 11
    let(:third_to_last) { thread_posts[8] } # post 10
    let(:tenth_to_last) { thread_posts[1] } # post 3

    def pin!(target)
      topic.custom_fields["mod_topic_pinned_post_id"] = target.id
      topic.save_custom_fields(true)
    end

    def visit_at(target)
      visit("/t/#{topic.slug}/#{topic.id}/#{target.post_number}")
      expect(page).to have_css("#topic-title", wait: 10)
    end

    it "pins a post from the post admin (moderator actions) menu" do
      sign_in(moderator)
      visit("/t/#{topic.slug}/#{topic.id}")
      expect(page).to have_css("#topic-title", wait: 10)

      within(first(".topic-post")) do
        find(".show-more-actions").click if has_css?(".show-more-actions", wait: 2)
        find(".show-post-admin-menu", match: :first).click
      end
      expect(page).to have_css(".mod-pin-post-to-bottom", wait: 10)
      shot("25_post_admin_menu_pin_option")

      find(".mod-pin-post-to-bottom").click
      expect(page).to have_css(".topic-footer-pinned-post", wait: 10)
      # The username and avatar in the bottom copy come from the server
      # response payload (mod_topic_pinned_post), not from the loaded
      # post-stream. Asserting they render confirms the live-render fix
      # for the "footer empty until reload" bug.
      expect(page).to have_css(
        ".topic-footer-pinned-post .pinned-post-username",
        text: post.user.username,
      )
      expect(page).to have_css(".topic-footer-pinned-post .pinned-post-avatar")
      shot("26_post_pinned_to_bottom")

      expect(topic.reload.custom_fields["mod_topic_pinned_post_id"]).to be_present
    end

    it "renders a copy at the bottom and a pin badge on the original" do
      pin!(tenth_to_last)
      sign_in(user)
      visit_at(tenth_to_last)

      expect(page).to have_css(".topic-footer-pinned-post", wait: 10)
      expect(page).to have_css(".topic-footer-pinned-post .pinned-post-badge")
      expect(page).to have_css(".topic-footer-pinned-post .pinned-post-avatar")
      expect(page).to have_css(".topic-footer-pinned-post a.pinned-post-jump")
      # The original post in the stream is badged too.
      expect(page).to have_css(".mod-pinned-in-stream-badge")
      expect(page).to have_no_css(".topic-footer-pinned-post.topic-footer-message")
      shot("39_pinned_post_as_bottom_post")
    end

    it "shows a footer message and a pinned post together" do
      topic.custom_fields["mod_topic_footer_message"] = footer_text
      topic.custom_fields["mod_topic_pinned_post_id"] = third_to_last.id
      topic.save_custom_fields(true)
      sign_in(user)
      visit_at(third_to_last)

      expect(page).to have_css(".topic-footer-pinned-post", wait: 10)
      expect(page).to have_css(
        ".topic-footer-message:not(.topic-footer-pinned-post)",
        text: "This thread is for app uploads only",
      )
      shot("27_footer_message_and_pinned_post_together")
    end

    # With "support mixed text direction" on, core marks each paragraph of a
    # post in the stream to read in its own direction. The copy at the bottom
    # and the footer message are rendered outside the stream and weren't: in
    # a Hebrew interface an English post's full stops came first
    it "reads the bottom copy and the footer message in their own direction" do
      SiteSetting.support_mixed_text_direction = true
      SiteSetting.default_locale = "he"
      topic.custom_fields["mod_topic_footer_message"] = footer_text
      topic.custom_fields["mod_topic_pinned_post_id"] = third_to_last.id
      topic.save_custom_fields(true)
      sign_in(user)
      visit_at(third_to_last)

      expect(page).to have_css("html.rtl .topic-footer-pinned-post .cooked p", wait: 10)
      expect(page).to have_css(".topic-footer-message-content p[dir='auto']")
      directions = page.evaluate_script(<<~JS)
        [".topic-footer-pinned-post .cooked > p", ".topic-footer-message-content > p"].map(
          (selector) => getComputedStyle(document.querySelector(selector)).direction
        )
      JS
      expect(directions).to eq(%w[ltr ltr])
    end

    it "unpins a post from the post admin menu" do
      pin!(tenth_to_last)
      sign_in(moderator)
      visit_at(tenth_to_last)
      expect(page).to have_css(".topic-footer-pinned-post", wait: 10)
      shot("28_pinned_post_before_unpin")

      within(find("#post_#{tenth_to_last.post_number}")) do
        find(".show-more-actions").click if has_css?(".show-more-actions", wait: 2)
        find(".show-post-admin-menu", match: :first).click
      end
      find(".mod-pin-post-to-bottom").click

      expect(page).to have_no_css(".topic-footer-pinned-post", wait: 10)
      shot("29_pinned_post_after_unpin")
      expect(topic.reload.custom_fields["mod_topic_pinned_post_id"]).to be_blank
    end

    context "depending on how far the pinned post is from the end" do
      before { sign_in(user) }

      it "the last post: only a pin badge on the original, no copy" do
        pin!(last_post)
        visit_at(last_post)

        expect(page).to have_css(".mod-pinned-in-stream-badge", wait: 10)
        expect(page).to have_no_css(".topic-footer-pinned-post")
        shot("42_pinned_last_post")
      end

      it "the second-to-last post: badge on the original plus a bottom copy" do
        pin!(second_to_last)
        visit_at(second_to_last)

        expect(page).to have_css(".mod-pinned-in-stream-badge", wait: 10)
        expect(page).to have_css(".topic-footer-pinned-post")
        shot("43_pinned_second_to_last")
      end

      it "the third-to-last post: badge on the original plus a bottom copy" do
        pin!(third_to_last)
        visit_at(third_to_last)

        expect(page).to have_css(".mod-pinned-in-stream-badge", wait: 10)
        expect(page).to have_css(".topic-footer-pinned-post")
        shot("44_pinned_third_to_last")
      end

      it "the tenth-to-last post: badge on the original plus a bottom copy" do
        pin!(tenth_to_last)
        visit_at(tenth_to_last)

        expect(page).to have_css(".mod-pinned-in-stream-badge", wait: 10)
        expect(page).to have_css(".topic-footer-pinned-post")
        shot("45_pinned_tenth_to_last")
      end
    end
  end

  context "navigating between topics with and without moderator messages" do
    fab!(:other_topic) do
      Fabricate(:topic, category: category, title: "A plain unmoderated thread")
    end
    fab!(:other_post) do
      Fabricate(:post, topic: other_topic, raw: "Just an ordinary topic with nothing special.")
    end

    before do
      topic.custom_fields["mod_topic_footer_message"] = footer_text
      topic.custom_fields["mod_topic_private_note"] = "Watch this one — staff only."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.custom_fields["mod_topic_private_note_created_at"] = 2.hours.ago.iso8601
      topic.save_custom_fields(true)
      sign_in(moderator)
    end

    # Navigates to a topic by clicking its title in the category topic list,
    # exercising the SPA router (no full page reload). A full reload would
    # build fresh connector instances and hide the staleness bug.
    def navigate_to_topic(title)
      visit("/c/#{category.slug}/#{category.id}")
      expect(page).to have_css(".topic-list-item", wait: 10)
      find(".topic-list-item a.title", text: title, match: :first).click
      expect(page).to have_css("#topic-title", wait: 10)
    end

    it "does not carry the footer or private note onto a topic that has neither" do
      navigate_to_topic("Share your app build here")
      expect(page).to have_css(".topic-footer-message", text: footer_text, wait: 10)
      expect(page).to have_css(".mod-private-note", wait: 10)
      shot("89_messages_on_first_topic")

      # SPA navigation to a topic with no moderator messages: the reused
      # connector must drop the previous topic's footer/note.
      navigate_to_topic("A plain unmoderated thread")
      expect(page).to have_no_css(".topic-footer-message")
      expect(page).to have_no_css(".mod-private-note")
      shot("90_no_stale_messages_on_second_topic")

      # Navigate back — the original topic's messages reappear.
      navigate_to_topic("Share your app build here")
      expect(page).to have_css(".topic-footer-message", text: footer_text, wait: 10)
      expect(page).to have_css(".mod-private-note", wait: 10)
      shot("91_messages_restored_on_first_topic")
    end
  end

  context "the moderator-notes user-menu tab" do
    before do
      topic.custom_fields["mod_topic_private_note"] = "Please review this thread."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.custom_fields["mod_topic_private_note_activity_at"] = Time.zone.now.iso8601
      topic.save_custom_fields(true)
      sign_in(moderator)
    end

    it "shows a shield tab in the user menu listing moderator notes" do
      visit("/")
      find(".header-dropdown-toggle.current-user").click
      expect(page).to have_css("#user-menu-button-discourse-mod-notes", wait: 10)
      shot("49_user_menu_shield_tab")

      find("#user-menu-button-discourse-mod-notes").click
      expect(page).to have_css(
        ".mod-notes-panel .mod-notes-item",
        text: "Please review this thread",
        wait: 10,
      )
      shot("50_moderator_notes_tab_panel")
    end
  end

  context "a moderator note notifies another staff member" do
    fab!(:other_moderator, :moderator)

    before do
      # The note (and its fan-out notification) is created directly so the
      # spec focuses on how the OTHER staff member sees and follows it.
      topic.custom_fields["mod_topic_private_note"] = "Please review this thread."
      topic.custom_fields["mod_topic_private_note_user_id"] = moderator.id
      topic.custom_fields["mod_topic_private_note_created_at"] = Time.zone.now.iso8601
      topic.custom_fields["mod_topic_private_note_activity_at"] = Time.zone.now.iso8601
      topic.save_custom_fields(true)

      note_url = "#{topic.relative_url}/#{topic.reload.highest_post_number}#mod-private-note"
      Notification.create!(
        notification_type: Notification.types[:custom],
        user_id: other_moderator.id,
        topic_id: topic.id,
        post_number: topic.highest_post_number,
        high_priority: true,
        data: {
          topic_title: topic.title,
          display_username: moderator.username,
          mod_note: true,
          url: note_url,
          message: "discourse_mod_categories.note_notification",
          title: "discourse_mod_categories.note_notification_title",
        }.to_json,
      )
      sign_in(other_moderator)
    end

    it "shows a clear notification that links to the moderator note" do
      visit("/")
      find(".header-dropdown-toggle.current-user").click

      # The moderator-note notification renders with accurate,
      # self-describing text in the bell list.
      expect(page).to have_css(".notification.custom", wait: 10)
      notification = find(".notification.custom", text: moderator.username, match: :first)
      expect(notification.text).to include("moderator note")
      # The link carries the note href and the "Moderator note" hover title.
      link = notification.find("a")
      expect(link[:title]).to eq("Moderator note")
      expect(link[:href]).to include("/t/")
      shot("95_mod_note_notification_in_user_menu")

      # Found again: opening the menu marks the notifications seen, and the
      # list can re-render between the checks above and the click.
      find(".notification.custom a[title='Moderator note']", match: :first).click

      # Clicking the notification lands on the topic — at the note, the same
      # target the notes feed uses.
      expect(page).to have_css("#topic-title", wait: 10)
      expect(current_path).to start_with("/t/")
      expect(current_path).to include(topic.id.to_s)
      shot("96_mod_note_notification_opened")
    end
  end
end
