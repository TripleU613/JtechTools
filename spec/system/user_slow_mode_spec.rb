# frozen_string_literal: true

require "rails_helper"

# Slow mode for one user, end to end: staff set it and lift it from the
# user's admin page, and the user sees it in their composer and is turned
# away when they post too soon. Screenshots at each step go to tmp/capybara/,
# published as the CI artifact.
RSpec.describe "User slow mode" do
  fab!(:moderator)
  fab!(:admin)
  fab!(:user) { Fabricate(:user, username: "eager_poster", trust_level: TrustLevel[2]) }
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category, title: "Which flip phone has the best battery?") }
  fab!(:op) { Fabricate(:post, topic: topic, raw: "Looking for something that lasts a few days.") }

  let(:admin_user_page) { PageObjects::Pages::AdminUser.new }
  let(:topic_page) { PageObjects::Pages::Topic.new }
  let(:composer) { PageObjects::Components::Composer.new }
  let(:dialog) { PageObjects::Components::Dialog.new }

  before do
    SiteSetting.mod_categories_enabled = true
    SiteSetting.min_post_length = 5
    SiteSetting.body_min_entropy = 1
  end

  def shot(name)
    begin
      Timeout.timeout(8) do
        sleep 0.1 until page.evaluate_script("Array.from(document.images).every((i) => i.complete)")
      end
    rescue Timeout::Error
      # Capture anyway rather than failing the spec over a slow image.
    end
    page.save_screenshot("slow_mode_#{name}.png")
  end

  it "lets a moderator put a user in slow mode from their admin page, and lift it" do
    sign_in(moderator)
    admin_user_page.visit(user)

    expect(page).to have_css(".mod-user-slow-mode__status", text: "No")
    find(".mod-user-slow-mode__status").scroll_to(:center)
    shot("01_admin_page")

    find(".mod-user-slow-mode__set").click
    expect(page).to have_css(".mod-user-slow-mode-modal")
    expect(page).to have_button(
      I18n.t("js.discourse_mod_categories.slow_mode.modal.save"),
      disabled: true,
    )
    find(".mod-slow-mode-reason").fill_in(with: "Several posts a minute in the phones thread")
    shot("02_dialog")
    find(".mod-slow-mode-save").click

    expect(page).to have_no_css(".mod-user-slow-mode-modal")
    expect(page).to have_css(".mod-user-slow-mode__status", text: "One post every 15 minutes, until")
    shot("03_set")

    state = DiscourseModCategories::UserSlowMode.state_for(user.reload)
    expect(state.seconds).to eq(900)
    expect(state.ends_at).to be_within(5.minutes).of(1.week.from_now)

    find(".mod-user-slow-mode__lift").click
    dialog.click_yes

    expect(page).to have_css(".mod-user-slow-mode__status", text: "No")
    expect(DiscourseModCategories::UserSlowMode.state_for(user.reload)).to be_nil
  end

  it "takes another interval and an end date" do
    sign_in(admin)
    admin_user_page.visit(user)

    find(".mod-user-slow-mode__set").click
    find(".mod-slow-mode-interval").select(
      I18n.t("js.discourse_mod_categories.slow_mode.modal.custom_interval"),
    )
    find(".mod-slow-mode-minutes").fill_in(with: "90")
    find(".mod-slow-mode-duration").select(
      I18n.t("js.discourse_mod_categories.slow_mode.modal.forever"),
    )
    find(".mod-slow-mode-reason").fill_in(with: "Cooling off")
    find(".mod-slow-mode-save").click

    expect(page).to have_css(
      ".mod-user-slow-mode__status",
      exact_text: "One post every 1 hour 30 minutes",
    )
    state = DiscourseModCategories::UserSlowMode.state_for(user.reload)
    expect(state.seconds).to eq(90.minutes.to_i)
    expect(state.ends_at).to be_nil
  end

  it "shows no slow mode on a staff member's admin page" do
    sign_in(admin)
    admin_user_page.visit(moderator)

    expect(page).to have_css(".admin-user")
    expect(page).to have_no_css(".mod-user-slow-mode")
  end

  it "tells the user in their composer, and turns away a post that's too soon" do
    DiscourseModCategories::UserSlowMode.set!(
      user,
      actor: moderator,
      seconds: 15.minutes.to_i,
      ends_at: nil,
      reason: "Several posts a minute in the phones thread",
    )
    Fabricate(:post, topic: topic, user: user, raw: "The Kyocera lasts days.", created_at: 5.minutes.ago)
    sign_in(user)

    topic_page.visit_topic(topic)
    topic_page.click_footer_reply

    expect(page).to have_css(
      ".mod-slow-mode-note",
      text: "Slow mode: one post every 15 minutes. You can post again in 10 minutes.",
    )
    composer.fill_content("And the battery swaps out in seconds too.")
    shot("04_composer_note")

    composer.submit

    expect(dialog).to be_open
    expect(dialog).to have_content(
      I18n.t("discourse_mod_categories.slow_mode.too_soon", time_left: "9 minutes"),
    )
    shot("05_turned_away")
    expect(topic.posts.where(user: user).count).to eq(1)
  end

  it "keeps the note out of a private message" do
    DiscourseModCategories::UserSlowMode.set!(
      user,
      actor: moderator,
      seconds: 15.minutes.to_i,
      ends_at: nil,
      reason: "Several posts a minute in the phones thread",
    )
    SiteSetting.personal_message_enabled_groups = Group::AUTO_GROUPS[:trust_level_0]
    sign_in(user)

    visit("/new-message?username=#{moderator.username}")

    expect(composer).to be_opened
    expect(page).to have_no_css(".mod-slow-mode-note")
  end
end
