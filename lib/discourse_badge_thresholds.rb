# frozen_string_literal: true

# Badge thresholds sized for JTech. Core's badge ladders assume a forum where
# posts reach 50 likes and people visit 365 days straight; here one post ever
# reached 25 likes and the longest streak is 171 days, so the silver and gold
# rungs were out of reach. Core and Solved re-seed these queries on every
# rebuild, so this sets them again afterwards (db/fixtures) and when the
# setting is turned on. Each rung reuses core's own query builder.
module ::DiscourseBadgeThresholds
  # Built when called: Badge isn't loaded yet when plugins load.
  def self.queries
    {
      Badge::GoodPost => BadgeQueries.like_badge(15, false),
      Badge::GreatPost => BadgeQueries.like_badge(20, false),
      Badge::GoodTopic => BadgeQueries.like_badge(15, true),
      Badge::GreatTopic => BadgeQueries.like_badge(20, true),
      Badge::GoodShare => BadgeQueries.sharing_badge(100),
      Badge::GreatShare => BadgeQueries.sharing_badge(300),
      Badge::HotLink => BadgeQueries.linking_badge(100),
      Badge::FamousLink => BadgeQueries.linking_badge(300),
      Badge::Admired => BadgeQueries.liked_posts(100, 5),
      Badge::HigherLove => BadgeQueries.like_rate_limit(3),
      Badge::CrazyInLove => BadgeQueries.like_rate_limit(10),
      Badge::Aficionado => BadgeQueries.consecutive_visits(30),
      Badge::Devotee => BadgeQueries.consecutive_visits(100),
    }
  end

  # Solved builds its queries inside its fixture; only the count differs per
  # rung, so that's all this changes.
  SOLUTIONS = { "Solved 2" => 3, "Solved 3" => 10, "Solved 4" => 25 }.freeze

  def self.enabled?
    SiteSetting.jtech_enabled && SiteSetting.jtech_badge_thresholds
  end

  def self.apply!
    return unless enabled?

    queries.each { |id, query| Badge.where(id: id).update_all(query: query) }
    Badge
      .where(name: SOLUTIONS.keys)
      .each do |badge|
        query =
          badge.query.sub(
            /HAVING COUNT\(\*\) >= \d+/,
            "HAVING COUNT(*) >= #{SOLUTIONS[badge.name]}",
          )
        badge.update_columns(query: query)
      end
  end
end
