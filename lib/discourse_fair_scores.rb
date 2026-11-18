# frozen_string_literal: true

# Leaderboard points that reward taking part, not volume. discourse-gamification
# counts every reply and every like the same, so one person posting all day or
# one fan liking everything decided the board. With jtech_fair_scores on, three
# of its scorers count only:
#
#   replies       the first N a person writes each day
#   likes in      N a day from any one person
#   likes out     the first N a person gives each day
#
# Points per action stay the plugin's own settings (post_created_score_value
# and so on) and each leaderboard's overrides. Off, the plugin's queries run
# unchanged.
module ::DiscourseFairScores
  def self.enabled?
    SiteSetting.jtech_enabled && SiteSetting.jtech_fair_scores
  end

  # Each returns the plugin's scorer shape: user_id, date, points, with :since
  # bound by the caller.
  def self.replies_sql(points:, category_filter: "")
    capped(SiteSetting.jtech_fair_scores_replies_per_day, points, <<~SQL)
      SELECT p.user_id AS user_id, date_trunc('day', p.created_at) AS date, COUNT(*) AS n
      FROM posts AS p
      INNER JOIN topics AS t ON t.id = p.topic_id #{category_filter}
      WHERE p.deleted_at IS NULL AND t.deleted_at IS NULL
        AND t.archetype <> 'private_message'
        AND p.post_number <> 1 AND p.post_type = 1
        AND p.wiki IS FALSE AND p.hidden IS FALSE
        AND p.created_at >= :since
      GROUP BY 1, 2
    SQL
  end

  def self.likes_received_sql(points:, category_filter: "")
    capped(SiteSetting.jtech_fair_scores_likes_per_person_per_day, points, <<~SQL)
      SELECT p.user_id AS user_id, date_trunc('day', pa.created_at) AS date, COUNT(*) AS n
      FROM post_actions AS pa
      INNER JOIN posts AS p ON p.id = pa.post_id
      INNER JOIN topics AS t ON t.id = p.topic_id #{category_filter}
      WHERE #{like_conditions}
      GROUP BY p.user_id, pa.user_id, 2
    SQL
  end

  def self.likes_given_sql(points:, category_filter: "")
    capped(SiteSetting.jtech_fair_scores_likes_given_per_day, points, <<~SQL)
      SELECT pa.user_id AS user_id, date_trunc('day', pa.created_at) AS date, COUNT(*) AS n
      FROM post_actions AS pa
      INNER JOIN posts AS p ON p.id = pa.post_id
      INNER JOIN topics AS t ON t.id = p.topic_id #{category_filter}
      WHERE #{like_conditions}
      GROUP BY 1, 2
    SQL
  end

  # An unliked like is soft-deleted; it no longer counts.
  def self.like_conditions
    <<~SQL
      p.deleted_at IS NULL AND pa.deleted_at IS NULL
        AND t.archetype <> 'private_message' AND p.wiki IS FALSE
        AND pa.post_action_type_id = #{PostActionType::LIKE_POST_ACTION_ID}
        AND pa.created_at >= :since
    SQL
  end

  def self.capped(cap, points, counts)
    <<~SQL
      SELECT user_id, date, (SUM(LEAST(n, #{cap.to_i})) * #{points.to_i})::integer AS points
      FROM (#{counts}) AS counts
      GROUP BY 1, 2
    SQL
  end

  BUILDERS = {
    "PostCreated" => :replies_sql,
    "LikeReceived" => :likes_received_sql,
    "LikeGiven" => :likes_given_sql,
  }.freeze

  # Prepended onto the plugin's scorer classes.
  module ScorerQuery
    def query(leaderboard: nil)
      return super unless ::DiscourseFairScores.enabled?

      ::DiscourseFairScores.public_send(
        ::DiscourseFairScores::BUILDERS.fetch(name.demodulize),
        points: score_multiplier(leaderboard:),
        category_filter: category_filter(leaderboard:),
      )
    end
  end

  def self.patch_gamification!
    return unless defined?(::DiscourseGamification::Scorable)

    BUILDERS.each_key do |klass|
      scorer = "::DiscourseGamification::#{klass}".safe_constantize
      scorer&.singleton_class&.prepend(ScorerQuery)
    end
  end
end
