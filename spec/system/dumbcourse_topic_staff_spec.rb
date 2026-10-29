# frozen_string_literal: true

require "rails_helper"

# Dumbcourse's topic menu for staff: core's topic admin menu (pin, banner,
# convert, timers, timestamp, bump date, slow mode, delete permanently), on a
# keypad phone, checked against what the server ends up with.
RSpec.describe "Dumbcourse topic staff actions" do
  fab!(:category) { Fabricate(:category, name: "Flip Phones") }
  fab!(:other_category) { Fabricate(:category, name: "Accessories") }
  fab!(:admin) { Fabricate(:admin, username: "admin_a") }
  fab!(:moderator) { Fabricate(:moderator, username: "mod_m") }
  fab!(:alice) { Fabricate(:user, username: "alice_k", trust_level: TrustLevel[2]) }
  fab!(:topic) do
    Fabricate(
      :topic,
      user: alice,
      category: category,
      title: "Looking for a good kosher flip phone",
    )
  end
  fab!(:op) { Fabricate(:post, topic: topic, user: alice, raw: "Which one has the best battery?") }

  before do
    SiteSetting.dumbcourse_enabled = true
    SiteSetting.personal_message_enabled_groups = Group::AUTO_GROUPS[:trust_level_0]
  end

  def press(*keys)
    keys.each do |k|
      page.send_keys(k)
      sleep 0.05
    end
  end

  def phone(&block)
    resize_window(width: 240, height: 320, &block)
  end

  def open_topic_menu
    visit "/dumb/t/#{topic.slug}/#{topic.id}"
    expect(page).to have_css(".topic-head")
    press(:f2)
    expect(page).to have_css(".sheet-heading", text: /moderation/i)
  end

  def pick(text)
    find(".sheet-item", text: text, match: :first).click
  end

  it "pins a topic globally for a week, and unpins it" do
    sign_in(moderator)
    phone do
      open_topic_menu
      pick("Pin…")
      pick("Pin globally")
      pick("1 week")
      expect(page).to have_css(".toast", text: "Pinned.")
    end
    topic.reload
    expect(topic.pinned_globally).to eq(true)
    expect(topic.pinned_until).to be_within(1.hour).of(1.week.from_now)

    phone do
      open_topic_menu
      pick("Unpin (pinned globally)")
      expect(page).to have_css(".toast", text: "Unpinned.")
    end
    expect(topic.reload.pinned_at).to be_nil
  end

  it "sets a timer to close the topic, shows it, and removes it" do
    sign_in(moderator)
    phone do
      open_topic_menu
      pick("Set timer…")
      pick("Close at a time")
      pick("In 1 day")
      expect(page).to have_css(".toast", text: "Timer set.")
    end
    timer = topic.reload.public_topic_timer
    expect(timer.status_type).to eq(TopicTimer.types[:close])
    expect(timer.execute_at).to be_within(1.hour).of(1.day.from_now)

    phone do
      open_topic_menu
      expect(page).to have_css(".sheet-item", text: "Set timer…")
      expect(page).to have_css(".sheet-hint", text: "Closes")
      pick("Set timer…")
      pick("Remove timer")
      expect(page).to have_css(".toast", text: "Timer removed.")
    end
    expect(topic.reload.public_topic_timer).to be_nil
  end

  it "closes a topic some time after its last reply" do
    sign_in(moderator)
    phone do
      open_topic_menu
      pick("Set timer…")
      pick("Close after the last reply")
      pick("12 hours")
      expect(page).to have_css(".toast", text: "Timer set.")
    end
    timer = topic.reload.public_topic_timer
    expect(timer.based_on_last_post).to eq(true)
    expect(timer.duration_minutes).to eq(720)
  end

  it "puts the topic in slow mode, and turns it off" do
    sign_in(moderator)
    phone do
      open_topic_menu
      pick("Slow mode…")
      pick("One post every 15 minutes")
      pick("No end")
      expect(page).to have_css(".toast", text: "Slow mode on.")
    end
    expect(topic.reload.slow_mode_seconds).to eq(900)

    phone do
      open_topic_menu
      pick("Slow mode…")
      pick("Turn off")
      expect(page).to have_css(".toast", text: "Slow mode off.")
    end
    expect(topic.reload.slow_mode_seconds).to eq(0)
  end

  it "changes the timestamp and resets the bump date" do
    sign_in(moderator)
    phone do
      open_topic_menu
      pick("Change timestamp…")
      find("#dlgInput").fill_in(with: "2025-01-02 10:30")
      find(".dialog [data-ok]").click
      expect(page).to have_css(".toast", text: "Timestamp changed.")
    end
    expect(topic.reload.created_at.to_date).to eq(Date.new(2025, 1, 2))

    topic.update_columns(bumped_at: 1.year.from_now)
    phone do
      open_topic_menu
      pick("Reset bump date")
      expect(page).to have_css(".toast", text: "Bump date reset.")
    end
    expect(topic.reload.bumped_at).to be < 1.minute.from_now
  end

  it "makes the topic a banner, and removes it" do
    sign_in(admin)
    phone do
      open_topic_menu
      pick("Make banner")
      find(".dialog [data-ok]").click
      expect(page).to have_css(".toast", text: "Made banner.")
    end
    expect(topic.reload.archetype).to eq(Archetype.banner)

    phone do
      open_topic_menu
      pick("Remove banner")
      expect(page).to have_css(".toast", text: "Banner removed.")
    end
    expect(topic.reload.archetype).to eq(Archetype.default)
  end

  it "turns the topic into a private message and back into a topic" do
    sign_in(admin)
    phone do
      open_topic_menu
      pick("Make private message")
      find(".dialog [data-ok]").click
      expect(page).to have_css(".toast", text: "Now a private message.")
    end
    expect(topic.reload.archetype).to eq(Archetype.private_message)

    phone do
      open_topic_menu
      pick("Make public topic")
      pick("Accessories")
      expect(page).to have_css(".toast", text: "Now a public topic.")
    end
    topic.reload
    expect(topic.archetype).to eq(Archetype.default)
    expect(topic.category_id).to eq(other_category.id)
  end

  it "deletes a deleted topic permanently" do
    SiteSetting.can_permanently_delete = true
    PostDestroyer.new(moderator, op).destroy
    expect(topic.reload.deleted_at).to be_present
    sign_in(admin)
    phone do
      open_topic_menu
      pick("Delete permanently")
      find(".dialog [data-ok]").click
      expect(page).to have_css(".toast", text: "Topic deleted permanently.")
    end
    expect(Topic.with_deleted.find_by(id: topic.id)).to be_nil
  end

  it "shows none of it to a regular user" do
    sign_in(alice)
    phone do
      visit "/dumb/t/#{topic.slug}/#{topic.id}"
      expect(page).to have_css(".topic-head")
      press(:f2)
      expect(page).to have_css(".sheet-item", text: "Copy link")
      expect(page).to have_no_css(".sheet-heading", text: /moderation/i)
      expect(page).to have_no_css(".sheet-item", text: "Set timer…")
    end
  end
end
