# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseBadgeThresholds do
  def query(id) = Badge.find(id).query

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_badge_thresholds = true
  end

  it "sets core's badges to this forum's thresholds with core's own builders" do
    described_class.apply!

    expect(query(Badge::GreatPost)).to eq(BadgeQueries.like_badge(20, false))
    expect(query(Badge::GoodTopic)).to eq(BadgeQueries.like_badge(15, true))
    expect(query(Badge::Admired)).to eq(BadgeQueries.liked_posts(100, 5))
    expect(query(Badge::Devotee)).to eq(BadgeQueries.consecutive_visits(100))
  end

  it "only builds queries the badge granter accepts" do
    described_class.apply!

    described_class.queries.each_key do |id|
      badge = Badge.find(id)
      result =
        BadgeGranter.preview(
          badge.query,
          target_posts: badge.target_posts,
          trigger: badge.trigger,
          explain: false,
        )
      expect(result[:errors]).to be_nil, "#{badge.name}: #{result[:errors]}"
    end
  end

  it "changes only the count in Solved's queries" do
    Badge.where(name: "Solved 3").destroy_all
    solved =
      "SELECT p.user_id, MAX(p.created_at) AS granted_at FROM badge_posts p GROUP BY p.user_id HAVING COUNT(*) >= 50"
    badge = Badge.create!(name: "Solved 3", badge_type_id: BadgeType::Gold, query: solved)

    described_class.apply!

    expect(badge.reload.query).to eq(solved.sub(">= 50", ">= 10"))
  end

  it "leaves core's thresholds alone when switched off" do
    SiteSetting.jtech_badge_thresholds = false

    expect { described_class.apply! }.not_to change { query(Badge::GreatPost) }
  end

  it "applies as soon as it's switched on" do
    SiteSetting.jtech_badge_thresholds = false
    Badge.where(id: Badge::GreatPost).update_all(query: BadgeQueries.like_badge(50, false))

    SiteSetting.jtech_badge_thresholds = true

    expect(query(Badge::GreatPost)).to eq(BadgeQueries.like_badge(20, false))
  end
end
