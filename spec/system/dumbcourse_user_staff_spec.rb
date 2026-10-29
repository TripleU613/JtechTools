# frozen_string_literal: true

require "rails_helper"

# What staff can do to a member from their Dumbcourse profile (core's admin
# user page actions, staff notes, this plugin's user slow mode), on a keypad
# phone, each checked against what the server ends up with.
RSpec.describe "Dumbcourse user staff actions" do
  fab!(:admin) { Fabricate(:admin, username: "admin_a") }
  fab!(:moderator) { Fabricate(:moderator, username: "mod_m") }
  fab!(:bob) { Fabricate(:user, username: "bob_r", trust_level: TrustLevel[1]) }
  fab!(:carol) { Fabricate(:user, username: "carol_t", trust_level: TrustLevel[2]) }

  before do
    SiteSetting.dumbcourse_enabled = true
    SiteSetting.personal_message_enabled_groups = Group::AUTO_GROUPS[:trust_level_0]
  end

  def phone(&block)
    resize_window(width: 240, height: 320, &block)
  end

  def open_moderate(user = bob)
    visit "/dumb/u/#{user.username}"
    find("[data-act=moderate-user]").click
    expect(page).to have_css(".sheet-title", text: "@#{user.username}")
  end

  def pick(text)
    find(".sheet-item", text: text, match: :first).click
  end

  def answer(text)
    find("#dlgInput").fill_in(with: text)
    find(".dialog [data-ok]").click
  end

  it "suspends a member and lifts it" do
    sign_in(moderator)
    phone do
      open_moderate
      pick("Suspend…")
      pick("1 week")
      answer("Spamming the classifieds")
      answer("")
      expect(page).to have_css(".toast", text: "Suspended.")
    end
    bob.reload
    expect(bob.suspended?).to eq(true)
    expect(bob.suspended_till).to be_within(1.hour).of(1.week.from_now)

    phone do
      open_moderate
      pick("Unsuspend")
      expect(page).to have_css(".toast", text: "Unsuspended.")
    end
    expect(bob.reload.suspended?).to eq(false)
  end

  it "silences a member" do
    sign_in(moderator)
    phone do
      open_moderate
      pick("Silence…")
      pick("3 days")
      answer("Arguing in every thread")
      answer("Take a few days off, please.")
      expect(page).to have_css(".toast", text: "Silenced.")
    end
    expect(bob.reload.silenced?).to eq(true)
  end

  it "changes the trust level and locks it" do
    sign_in(admin)
    phone do
      open_moderate
      pick("Trust level…")
      pick("3 · Regular")
      expect(page).to have_css(".toast", text: "Trust level changed.")
    end
    expect(bob.reload.trust_level).to eq(3)

    phone do
      open_moderate
      pick("Lock trust level")
      expect(page).to have_css(".toast", text: "Trust level locked.")
    end
    expect(bob.reload.manual_locked_trust_level).to eq(3)
  end

  it "puts a member in slow mode" do
    SiteSetting.mod_categories_enabled = true
    sign_in(moderator)
    phone do
      open_moderate
      pick("Slow mode…")
      pick("One post every 15 minutes")
      pick("1 week")
      answer("Several posts a minute")
      expect(page).to have_css(".toast", text: "Slow mode on.")
    end
    state = DiscourseModCategories::UserSlowMode.state_for(bob.reload)
    expect(state.seconds).to eq(900)
    expect(state.ends_at).to be_within(1.hour).of(1.week.from_now)
  end

  it "sends an official warning" do
    sign_in(moderator)
    phone do
      open_moderate
      pick("Send official warning…")
      expect(page).to have_css(".c-notice", text: "official warning")
      find("#cTitle").fill_in(with: "About your posts in Classifieds")
      find("#cText").fill_in(with: "Please keep listings to one per phone.")
      find("[data-c=send]").click
      expect(page).to have_css(".toast", text: "Message sent.")
    end
    expect(UserWarning.exists?(user_id: bob.id, created_by_id: moderator.id)).to eq(true)
  end

  it "makes a member a moderator, and adds them to a group" do
    group = Fabricate(:group, name: "testers")
    sign_in(admin)
    phone do
      open_moderate(carol)
      pick("Make moderator")
      find(".dialog [data-ok]").click
      expect(page).to have_css(".toast", text: "Now a moderator.")
    end
    expect(carol.reload.moderator).to eq(true)

    phone do
      open_moderate(carol)
      pick("Groups…")
      pick("Add to a group…")
      answer("testers")
      expect(page).to have_css(".toast", text: "Added to testers.")
    end
    expect(GroupUser.exists?(group_id: group.id, user_id: carol.id)).to eq(true)
  end

  it "leaves a staff note on a member", if: defined?(::DiscourseUserNotes) do
    SiteSetting.user_notes_enabled = true
    sign_in(moderator)
    phone do
      open_moderate
      pick("Staff notes")
      pick("Add a note…")
      answer("Warned by phone about reselling.")
      expect(page).to have_css(".toast", text: "Note added.")
    end
    expect(
      DiscourseUserNotes.notes_for(bob.id).map { |n| n.with_indifferent_access[:raw] },
    ).to include("Warned by phone about reselling.")
  end

  it "deletes an account" do
    sign_in(admin)
    phone do
      open_moderate
      pick("Delete account…")
      pick("Delete the account and its posts")
      find(".dialog [data-ok]").click
      expect(page).to have_css(".toast", text: "Account deleted.")
    end
    expect(User.find_by(id: bob.id)).to be_nil
  end

  it "shows a member no Moderate button" do
    sign_in(carol)
    phone do
      visit "/dumb/u/#{bob.username}"
      expect(page).to have_css(".profile-card")
      expect(page).to have_no_css("[data-act=moderate-user]")
    end
  end
end
