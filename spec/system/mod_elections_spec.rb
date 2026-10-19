# frozen_string_literal: true

require "rails_helper"

# Mod elections in the browser: running, ranking candidates on a ballot,
# reading the results, and an admin publishing them. Set
# JTECH_SCREENSHOT_GALLERY=1 to also save screenshots
# (tmp/capybara/mod_elections_*.png).
RSpec.describe "Mod elections" do
  fab!(:admin)
  fab!(:moderator) do
    Fabricate(
      :moderator,
      username: "shalom_k",
      trust_level: TrustLevel[3],
      created_at: 1.year.ago,
      refresh_auto_groups: true,
    )
  end
  fab!(:chaim) do
    Fabricate(
      :user,
      username: "chaim_w",
      trust_level: TrustLevel[2],
      created_at: 1.year.ago,
      refresh_auto_groups: true,
    )
  end
  fab!(:dovid) do
    Fabricate(
      :user,
      username: "dovid_l",
      trust_level: TrustLevel[3],
      created_at: 1.year.ago,
      refresh_auto_groups: true,
    )
  end
  fab!(:voter) do
    Fabricate(
      :user,
      username: "rivka_s",
      trust_level: TrustLevel[3],
      created_at: 1.year.ago,
      refresh_auto_groups: true,
    )
  end

  let(:election) do
    DiscourseModElections::Lifecycle.create!(
      admin,
      seats: 2,
      nominations_open_at: 1.minute.ago,
      voting_open_at: 3.days.from_now,
      voting_close_at: 6.days.from_now,
    )
  end

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.mod_elections_enabled = true
  end

  def shot(name)
    return unless ENV["JTECH_SCREENSHOT_GALLERY"]
    page.save_screenshot("mod_elections_#{name}.png")
  end

  def candidate_for(user)
    election.candidates.find_by(user: user)
  end

  def open_voting
    DiscourseModElections::Nominations.run!(
      chaim,
      election,
      "I answer most of the Android questions.",
    )
    DiscourseModElections::Nominations.run!(dovid, election, "")
    DiscourseModElections::Lifecycle.end_phase!(election, admin)
  end

  it "shows the banner as a card with the way in, and keeps it closed once closed" do
    election
    sign_in(chaim)
    visit "/latest"

    banner = find(".global-notice .mod-elections-notice")
    expect(banner).to have_css(".mod-elections-notice__label", text: "Mod elections")
    expect(banner).to have_css(".mod-elections-notice__title", text: "Nominations are open")
    expect(banner).to have_css(".mod-elections-notice__detail", text: "Until")
    expect(banner).to have_css(
      "a.btn.mod-elections-notice__link[href$='/elections']",
      text: "Run, or see who's running",
    )
    shot("00_banner")

    banner.find(".mod-elections-notice__link").click
    expect(page).to have_css(".mod-elections")

    find(".global-notice .close").click
    expect(page).to have_no_css(".global-notice .mod-elections-notice")
    visit "/latest"
    expect(page).to have_css("#main-outlet")
    expect(page).to have_no_css(".global-notice .mod-elections-notice")
  end

  it "lets a member run for mod with a statement" do
    election
    sign_in(chaim)
    visit "/elections"

    expect(page).to have_css(".mod-elections-candidate", text: moderator.username)
    find(".mod-elections-run__start").click
    find(".mod-elections-run__statement").fill_in(with: "Fair and fast.")
    shot("01_run_form")
    find(".mod-elections-run__submit").click

    expect(page).to have_css(".mod-elections-run__status", text: "You're running.")
    expect(page).to have_css(".mod-elections-candidate", text: "Fair and fast.")
    expect(candidate_for(chaim).statement).to eq("Fair and fast.")
    shot("02_running")
  end

  it "builds a ranking with the buttons and saves it" do
    open_voting
    sign_in(voter)
    visit "/elections"

    expect(page).to have_css(".global-notice", text: "Vote Week is open")
    ballot = find(".mod-elections-ballot")
    [chaim, dovid].each do |user|
      ballot.find(
        ".mod-elections-ballot__pool [data-candidate-id='#{candidate_for(user).id}'] .mod-elections-ballot__add",
      ).click
    end
    ballot.find(
      ".mod-elections-ballot__ranking [data-candidate-id='#{candidate_for(dovid).id}'] .mod-elections-ballot__up",
    ).click
    shot("03_ballot_ranked")
    ballot.find(".mod-elections-ballot__save").click

    expect(page).to have_css(".mod-elections-ballot__state", text: "Saved")
    saved = DiscourseModElections::Ballot.find_by(election: election, user: voter)
    expect(saved.ranking).to eq([candidate_for(dovid).id, candidate_for(chaim).id])
    expect(saved.weight).to eq(3)

    visit "/elections"
    expect(page).to have_no_css(".global-notice", text: "Vote Week is open")
    places = all(".mod-elections-ballot__ranking .mod-elections-ballot__name").map(&:text)
    expect(places).to eq([dovid.username, chaim.username])
    shot("04_ballot_saved")
  end

  it "drags candidates into place on desktop and reads out each change" do
    open_voting
    sign_in(voter)
    visit "/elections"

    pool_row = ->(user) do
      find(".mod-elections-ballot__pool [data-candidate-id='#{candidate_for(user).id}']")
    end
    pool_row.call(chaim).drag_to(find(".mod-elections-ballot__dropzone"))
    # Core's live region reads each change out.
    expect(page).to have_css("#a11y-announcements-polite", text: "chaim_w ranked 1.", visible: :all)

    pool_row.call(dovid).drag_to(
      find(".mod-elections-ballot__ranking li", text: chaim.username),
      delay: 0.05,
    )
    names = -> { all(".mod-elections-ballot__ranking .mod-elections-ballot__name").map(&:text) }
    expect(names.call).to contain_exactly(dovid.username, chaim.username)

    # Each button says whose it is.
    expect(page).to have_css(".mod-elections-ballot__up[aria-label='Move #{chaim.username} up']")
    expect(page).to have_css(
      ".mod-elections-ballot__remove[aria-label='Take #{dovid.username} off your ranking']",
    )

    find(".mod-elections-ballot__ranking li", text: dovid.username).drag_to(
      find(".mod-elections-ballot__pool"),
    )
    expect(names.call).to eq([chaim.username])
    expect(page).to have_css(
      "#a11y-announcements-polite",
      text: "#{dovid.username} taken off your ranking.",
      visible: :all,
    )
  end

  it "moves the page on by itself when a step changes" do
    open_voting
    sign_in(voter)
    visit "/elections"
    expect(page).to have_css(".mod-elections-ballot")

    DiscourseModElections::Lifecycle.end_phase!(election, admin)

    expect(page).to have_css(".mod-elections-status", text: "Counting")
    expect(page).to have_no_css(".mod-elections-ballot")
  end

  it "works the same in mobile mode", mobile: true do
    open_voting
    sign_in(voter)
    visit "/elections"

    find(
      ".mod-elections-ballot__pool [data-candidate-id='#{candidate_for(chaim).id}'] .mod-elections-ballot__add",
    ).click
    find(".mod-elections-ballot__save").click

    expect(page).to have_css(".mod-elections-ballot__state", text: "Saved")
    expect(DiscourseModElections::Ballot.find_by(election: election, user: voter).ranking).to eq(
      [candidate_for(chaim).id],
    )
    shot("08_mobile_ballot")
  end

  it "ranks on a flip phone: a candidate, then the number of their place" do
    open_voting
    SiteSetting.dumbcourse_enabled = true
    sign_in(voter)

    resize_window(width: 240, height: 320) do
      visit "/dumb/elections"
      expect(page).to have_css("button.row[data-act='cand']", count: 3)
      { dovid => "1", chaim => "2", moderator => "1" }.each do |user, key|
        page.execute_script(
          "document.querySelector(\"[data-id='#{candidate_for(user).id}']\").focus()",
        )
        page.send_keys(key)
        sleep 0.1
      end
      shot("07_dumbcourse_ranked")
      find("[data-act='save']").click
      expect(page).to have_text("Ballot saved.")
    end

    saved = DiscourseModElections::Ballot.find_by(election: election, user: voter)
    expect(saved.ranking).to eq(
      [candidate_for(moderator).id, candidate_for(dovid).id, candidate_for(chaim).id],
    )
  end

  it "says nominations stay open longer when nobody else runs, then that there's no Vote Week" do
    election
    DiscourseModElections::Lifecycle.advance!(election, election.voting_open_at)
    sign_in(chaim)
    visit "/elections"

    expect(page).to have_css(".global-notice", text: "nominations stay open until")
    expect(page).to have_css(".mod-elections-extended")
    expect(page).to have_css(".mod-elections-run__start")

    DiscourseModElections::Lifecycle.end_phase!(election, admin)

    expect(page).to have_css(".mod-elections-status", text: "Unopposed")
    expect(page).to have_css(".mod-elections-vote-skipped", text: "elected unopposed")
    expect(page).to have_css(".mod-elections-steps__step", count: 2)
    expect(page).to have_no_css(".mod-elections-steps__step[data-step='voting']")
    expect(page).to have_css(".mod-elections-candidate", text: moderator.username)
    shot("09_vote_skipped")

    SiteSetting.dumbcourse_enabled = true
    resize_window(width: 240, height: 320) do
      visit "/dumb/elections"
      expect(page).to have_text("Unopposed")
      expect(page).to have_text("elected unopposed")
    end
  end

  it "doesn't offer a candidate their own name" do
    open_voting
    sign_in(chaim)
    visit "/elections"

    row = find(".mod-elections-ballot__pool [data-candidate-id='#{candidate_for(chaim).id}']")
    expect(row).to have_no_css(".mod-elections-ballot__add")
    expect(row).to have_text("You")
  end

  it "lets an admin change the seats and the dates still ahead" do
    open_voting
    sign_in(admin)
    visit "/admin/plugins/jtech-tools/mod-elections"
    find(".mod-elections-admin__edit-button").click

    # In Vote Week only the seats and its end can change
    # A date cleared by mistake gets a word, not a form that does nothing
    find(".mod-elections-admin__edit input[type='datetime-local']").fill_in(with: "")
    find(".mod-elections-admin__save-edit").click
    expect(page).to have_css(".dialog-body", text: "Fill in every date")
    find(".dialog-footer .btn-primary").click
    expect(election.reload.voting_close_at).to be > Time.zone.now
    find(".mod-elections-admin__edit + .mod-elections-actions .btn-flat").click
    find(".mod-elections-admin__edit-button").click

    within(".mod-elections-admin__edit") do
      expect(page).to have_css("input[type='datetime-local']", count: 1)
      find(".mod-elections-admin__seats").fill_in(with: "3")
    end
    shot("11_admin_edit")
    find(".mod-elections-admin__save-edit").click

    expect(page).to have_no_css(".mod-elections-admin__edit")
    expect(page).to have_css(".mod-elections-admin__seat-count", text: "3 seats")
    expect(election.reload.seats).to eq(3)
    shot("12_admin_edited")

    sign_in(voter)
    visit "/elections"
    expect(page).to have_css(".mod-elections__meta", text: "3 seats")
  end

  it "lets an admin check the count before publishing it, then shows the results" do
    open_voting
    DiscourseModElections::Voting.cast!(voter, election, [candidate_for(chaim).id])
    DiscourseModElections::Voting.cast!(dovid, election, [candidate_for(chaim).id])
    DiscourseModElections::Lifecycle.end_phase!(election, admin)

    sign_in(admin)
    visit "/admin/plugins/jtech-tools/mod-elections"
    find(".mod-elections-admin__preview").click
    expect(page).to have_css(".mod-elections-results__winner", text: chaim.username)
    shot("05_admin_preview")
    find(".mod-elections-admin__publish").click
    find(".dialog-footer .btn-primary").click

    expect(page).to have_css(".mod-elections-admin__seats-list", text: chaim.username)
    expect(chaim.reload).to be_moderator

    sign_in(voter)
    visit "/elections"
    expect(page).to have_css(".mod-elections-status", text: "Results")
    expect(page).to have_css(".mod-elections-receipt", text: "Your ballot was counted.")
    expect(page).to have_css(".mod-elections-results__row--elected", text: chaim.username)
    expect(page).to have_css(".mod-elections-results__table th", text: "First choices")
    shot("06_results")
  end

  it "holds publishing while a winner can't take the seat, until an admin takes them off" do
    open_voting
    election.update!(seats: 1)
    DiscourseModElections::Voting.cast!(voter, election, [candidate_for(chaim).id])
    DiscourseModElections::Voting.cast!(dovid, election, [candidate_for(chaim).id])
    DiscourseModElections::Voting.cast!(
      moderator,
      election,
      [candidate_for(dovid).id, candidate_for(chaim).id],
    )
    DiscourseModElections::Lifecycle.end_phase!(election, admin)
    chaim.update!(suspended_till: 1.month.from_now, suspended_at: Time.zone.now)

    sign_in(admin)
    visit "/admin/plugins/jtech-tools/mod-elections"
    find(".mod-elections-admin__preview").click

    expect(page).to have_css(
      ".mod-elections-admin__problems",
      text: "#{chaim.username} is suspended.",
    )
    expect(page).to have_css(".mod-elections-admin__publish[disabled]")

    row = find(".mod-elections-admin__table tr[data-candidate-id='#{candidate_for(chaim).id}']")
    row.find(".mod-elections-admin__disqualify").click
    row.find(".mod-elections-admin__reason").fill_in(with: "Suspended after the vote")
    row.find(".btn-danger").click

    # The old preview is gone: it showed a count that no longer stands.
    expect(page).to have_no_css(".mod-elections-results")
    find(".mod-elections-admin__preview").click
    expect(page).to have_css(".mod-elections-results__winner", text: dovid.username)
    expect(page).to have_no_css(".mod-elections-admin__problems")
    expect(page).to have_no_css(".mod-elections-admin__publish[disabled]")
  end

  it "shows every tie the count broke, and how" do
    open_voting
    # One seat, two level candidates, nothing between them at any stage.
    election.update!(seats: 1)
    DiscourseModElections::Voting.cast!(voter, election, [candidate_for(chaim).id])
    DiscourseModElections::Voting.cast!(moderator, election, [candidate_for(dovid).id])
    DiscourseModElections::Lifecycle.end_phase!(election, admin)
    DiscourseModElections::Publisher.publish!(election, admin)

    sign_in(voter)
    visit "/elections"
    expect(page).to have_css(
      ".mod-elections-results__ties li",
      text: /level on the fewest votes at every stage, so a lot put \S+ out \(seed \d+\)/,
    )
  end
end
