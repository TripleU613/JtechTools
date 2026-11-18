# frozen_string_literal: true

RSpec.describe DiscourseMarketAccounts do
  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_market_account_retention = true
    SiteSetting.jtech_market_origin = "https://market.jtechforums.org"
  end

  it "protects marketplace members while ordinary inactive users are still deleted" do
    SiteSetting.clean_up_inactive_users_after_days = 14
    old = 30.days.ago
    member = Fabricate(:user, trust_level: 0, created_at: old, last_seen_at: old)
    ordinary = Fabricate(:user, trust_level: 0, created_at: old, last_seen_at: old)
    described_class.protect!(member)
    described_class.protect!(member)
    expect(UserCustomField.where(user_id: member.id, name: described_class::FIELD).count).to eq(1)

    Jobs::CleanUpInactiveUsers.new.execute({})

    expect(User.exists?(member.id)).to eq(true)
    expect(User.exists?(ordinary.id)).to eq(false)
    expect(SiteSetting.clean_up_inactive_users_after_days).to eq(14)
  end

  it "honors both feature switches without erasing existing protection" do
    member = Fabricate(:user)
    described_class.protect!(member)
    SiteSetting.jtech_enabled = false
    expect(described_class.cleanup_scope(User.where(id: member.id))).to exist
    other = Fabricate(:user)
    described_class.protect!(other)
    expect(UserCustomField.exists?(user_id: other.id, name: described_class::FIELD)).to eq(false)
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_market_account_retention = false
    expect(described_class.cleanup_scope(User.where(id: member.id))).to exist
    SiteSetting.jtech_market_account_retention = true
    expect(described_class.cleanup_scope(User.where(id: member.id))).not_to exist
  end

  it "accepts only the configured HTTPS marketplace callback" do
    expect(
      described_class.market_callback?(
        "https://market.jtechforums.org/api/v1/auth/discourse/callback",
      ),
    ).to eq(true)
    %w[
      http://market.jtechforums.org/api/v1/auth/discourse/callback
      https://market.jtechforums.org.evil.test/api/v1/auth/discourse/callback
      https://market.jtechforums.org:444/api/v1/auth/discourse/callback
      https://market.jtechforums.org/not-marketplace
      https://someone@market.jtechforums.org/api/v1/auth/discourse/callback
      https://market.jtechforums.org/api/v1/auth/discourse/callback#fragment
    ].each { |url| expect(described_class.market_callback?(url)).to eq(false) }
  end
end
