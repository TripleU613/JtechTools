# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseJtechBadges do
  fab!(:admin)
  fab!(:alice) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:bob) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:carol) { Fabricate(:user, trust_level: TrustLevel[2]) }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.mod_elections_enabled = true
    SiteSetting.reqpm_enabled = true
    SiteSetting.listing_format_enabled = true
    SiteSetting.dumbcourse_enabled = true
    SiteSetting.popup_notifications_enabled = true
    described_class.seed!
    # The test database may have them from its own seeding, switched off then
    described_class::SWITCHES.each_key { |set| described_class.refresh!(set) }
  end

  def badge(name) = Badge.find_by!(name: name)

  def holders(name)
    BadgeGranter.backfill(badge(name))
    UserBadge.where(badge: badge(name)).pluck(:user_id)
  end

  it "seeds every badge, on, with a query the badge granter accepts" do
    described_class.badges.each do |d|
      b = badge(d[:name])
      expect(b).to be_enabled
      result =
        BadgeGranter.preview(b.query, target_posts: false, trigger: b.trigger, explain: false)
      expect(result[:errors]).to be_nil, "#{b.name}: #{result[:errors]}"
    end
  end

  it "switches a module's badges off and on with the module" do
    SiteSetting.mod_elections_enabled = false
    expect(badge("Elected")).not_to be_enabled
    expect(badge("Seller")).to be_enabled

    SiteSetting.mod_elections_enabled = true
    expect(badge("Elected")).to be_enabled
  end

  describe "elections" do
    def election(status, **attrs)
      DiscourseModElections::Election.create!(
        status: status,
        seats: 1,
        nominations_open_at: 3.weeks.ago,
        voting_open_at: 2.weeks.ago,
        voting_close_at: 1.week.ago,
        **attrs,
      )
    end

    def candidate(election, user, status = :running, elected: false)
      DiscourseModElections::Candidate.create!(
        election: election,
        user: user,
        status: status,
        elected: elected,
      )
    end

    it "grants from the published results, and Constituent only for a counted ballot" do
      dave = Fabricate(:user)
      published = election(:published, published_at: 6.days.ago)
      candidate(published, alice, elected: true)
      candidate(published, bob)
      candidate(published, carol, :withdrawn)
      candidate(published, dave, :disqualified)
      DiscourseModElections::Voter.create!(
        election: published,
        user: bob,
        weight: 2,
        receipt: "counted",
      )
      DiscourseModElections::Voter.create!(
        election: published,
        user: dave,
        weight: 2,
        receipt: "set_aside",
      )

      expect(holders("Elected")).to eq([alice.id])
      expect(holders("Runner-up")).to eq([bob.id])
      expect(holders("Stepped Aside")).to eq([carol.id])
      expect(holders("Candidate")).to contain_exactly(alice.id, bob.id, carol.id)
      expect(holders("Constituent")).to eq([bob.id])
      expect(holders("Re-elected")).to be_empty
    end

    it "makes nobody a candidate while nominations are still open" do
      candidate(election(:nominating), alice)
      expect(holders("Candidate")).to be_empty
    end

    it "gives Former Moderator to anyone once made a moderator who isn't one now" do
      moderator = Fabricate(:moderator)
      [alice, moderator].each { |u| StaffActionLogger.new(admin).log_grant_moderation(u) }

      expect(holders("Former Moderator")).to eq([alice.id])
    end
  end

  it "grants REQ-PM badges for a card and for sharing it" do
    card = DiscourseReqpm::ContactMethod.create!(user: alice, kind: "email", value: "a@example.com")
    DiscourseReqpm::Share.create!(owner: alice, recipient: bob, contact_method: card)

    expect(holders("Business Card")).to eq([alice.id])
    expect(holders("Connected")).to eq([alice.id])
    expect(holders("Networker")).to be_empty
  end

  it "counts listings in the for-sale topics, from their setting" do
    topic = Fabricate(:topic)
    Fabricate(:post, topic: topic, user: admin)
    listing = Fabricate(:post, topic: topic, user: alice)
    Fabricate(:post, user: bob)

    SiteSetting.listing_format_topics = topic.id.to_s
    expect(holders("Seller")).to eq([alice.id])

    listing.custom_fields[DiscourseListingFormat::SOLD_FIELD] = true
    listing.save_custom_fields
    expect(holders("First Sale")).to eq([alice.id])
  end

  it "counts Dumbcourse days once a day, and posts written in it" do
    freeze_time
    DiscourseDumbcourse::Usage.visit!(alice)
    DiscourseDumbcourse::Usage.visit!(alice)
    expect(alice.reload.custom_fields[DiscourseDumbcourse::Usage::DAYS_FIELD].to_i).to eq(1)
    DiscourseDumbcourse::Usage.visit!(alice, today: 1.day.from_now.utc.to_date)
    expect(alice.reload.custom_fields[DiscourseDumbcourse::Usage::DAYS_FIELD].to_i).to eq(2)
    expect(holders("Flip Phone")).to eq([alice.id])

    PostCreator.create!(
      bob,
      title: "Written on a keypad",
      raw: "Typed with T9, word by word.",
      dumbcourse: true,
    )
    PostCreator.create!(carol, title: "Written on a laptop", raw: "Typed on a full keyboard here.")
    expect(holders("T9 Typist")).to eq([bob.id])
  end

  it "gives Heads Up for turning pop-ups on, and Power User for every tool" do
    alice.custom_fields[DiscoursePopupNotifications::USER_ENABLED_FIELD] = true
    alice.save_custom_fields
    expect(holders("Heads Up")).to eq([alice.id])

    (described_class::POWER_USER_PARTS - ["Heads Up"]).each do |name|
      BadgeGranter.grant(badge(name), alice)
    end
    BadgeGranter.grant(badge("Constituent"), bob)
    expect(holders("Power User")).to eq([alice.id])
  end
end
