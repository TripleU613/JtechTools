# frozen_string_literal: true

# Badges for taking part in what Jtech adds: elections, REQ-PM, the for-sale
# thread, Dumbcourse and pop-ups, each one anyone can earn. They're seeded
# like core's (by name, on every rebuild, text in server.en.yml under
# badges.<name>) and are on only while their module is. The queries read the
# modules' own tables; Discourse's daily badge run grants them, and elections
# grant theirs as soon as nominations close and results are published.
module ::DiscourseJtechBadges
  # Each group and its place on /badges: after core's (0-5), Live (15) and
  # the Official, Honors and Developers groups (16-18).
  GROUPINGS = {
    elections: ["Elections", 19],
    marketplace: ["Marketplace", 20],
    reqpm: ["REQ-PM", 21],
    dumbcourse: ["Dumbcourse", 22],
  }.freeze

  # What turns each set on: its module, and with it jtech_enabled.
  SWITCHES = {
    elections: -> { DiscourseModElections.enabled? },
    marketplace: -> { DiscourseListingFormat.enabled? },
    reqpm: -> { DiscourseReqpm.enabled? },
    dumbcourse: -> { DiscourseDumbcourse.enabled? },
    popups: -> { SiteSetting.jtech_enabled && SiteSetting.popup_notifications_enabled },
    all: -> { SiteSetting.jtech_enabled },
  }.freeze

  # Settings that change a set: its switch, or (listings) what its queries read.
  SETTINGS = {
    mod_elections_enabled: :elections,
    listing_format_enabled: :marketplace,
    listing_format_topics: :marketplace,
    reqpm_enabled: :reqpm,
    dumbcourse_enabled: :dumbcourse,
    popup_notifications_enabled: :popups,
  }.freeze

  # The modules each count towards Power User, by the badge that shows it.
  POWER_USER_PARTS = ["Constituent", "Business Card", "Seller", "Flip Phone", "Heads Up"].freeze

  # Built when called: models and badge types aren't loaded yet when
  # plugins load.
  def self.badges
    bronze, silver, gold = BadgeType::Bronze, BadgeType::Silver, BadgeType::Gold
    [
      # Elections
      badge("Constituent", :elections, bronze, "check-to-slot", voted(1)),
      badge("Civic Duty", :elections, silver, "clipboard-check", voted(3)),
      badge("Candidate", :elections, bronze, "user-tie", candidates(%i[running withdrawn])),
      badge(
        "Stepped Aside",
        :elections,
        bronze,
        "person-walking-arrow-right",
        candidates(%i[withdrawn]),
      ),
      badge(
        "Runner-up",
        :elections,
        bronze,
        "ranking-star",
        candidates(%i[running], elected: false),
      ),
      badge("Elected", :elections, gold, "user-shield", candidates(%i[running], elected: true)),
      badge(
        "Re-elected",
        :elections,
        gold,
        "arrows-rotate",
        candidates(%i[running], elected: true, times: 2),
      ),
      badge("Former Moderator", :elections, silver, "shield", former_moderators, auto_revoke: true),
      # REQ-PM
      badge("Business Card", :reqpm, bronze, "address-card", <<~SQL),
        SELECT user_id, MIN(created_at) granted_at FROM reqpm_contact_methods GROUP BY user_id
      SQL
      badge("Connected", :reqpm, bronze, "handshake-simple", shared_with(1)),
      badge("Networker", :reqpm, silver, "network-wired", shared_with(5)),
      # The for-sale thread
      badge("Seller", :marketplace, bronze, "tag", listings(1)),
      badge("First Sale", :marketplace, bronze, "hand-holding-dollar", <<~SQL),
        SELECT p.user_id, MIN(p.created_at) granted_at
        FROM posts p
        JOIN post_custom_fields f ON f.post_id = p.id
        WHERE #{listing_posts("p")}
          AND f.name = '#{DiscourseListingFormat::SOLD_FIELD}' AND f.value = 't'
        GROUP BY p.user_id
      SQL
      badge("Merchant", :marketplace, silver, "store", listings(5)),
      badge("Trader", :marketplace, gold, "truck-fast", listings(10)),
      # Dumbcourse
      badge("Flip Phone", :dumbcourse, bronze, "mobile-retro", dumbcourse_days(1)),
      badge("Keypad Regular", :dumbcourse, silver, "calendar-days", dumbcourse_days(30)),
      badge("T9 Typist", :dumbcourse, bronze, "keyboard", dumbcourse_posts(1)),
      badge("T9 Master", :dumbcourse, gold, "mobile-button", dumbcourse_posts(100)),
      # Across the tools
      badge("Heads Up", :popups, bronze, "bell", <<~SQL, grouping: BadgeGrouping::GettingStarted),
        SELECT user_id, created_at granted_at FROM user_custom_fields
        WHERE name = '#{DiscoursePopupNotifications::USER_ENABLED_FIELD}' AND value = 't'
      SQL
      badge("Power User", :all, gold, "bolt", power_users, grouping: BadgeGrouping::Community),
    ]
  end

  def self.badge(name, set, type, icon, query, grouping: set, auto_revoke: false)
    { name:, set:, type:, icon:, query:, grouping:, auto_revoke: }
  end

  def self.seed!
    groupings =
      GROUPINGS.to_h do |key, (name, position)|
        BadgeGrouping.seed(:name) do |g|
          g.name = name
          g.default_position = position
        end
        [key, BadgeGrouping.find_by(name: name).id]
      end

    badges.each do |d|
      Badge.seed(:name) do |b|
        b.name = d[:name]
        b.badge_type_id = d[:type]
        b.default_icon = d[:icon]
        b.default_badge_grouping_id = groupings.fetch(d[:grouping], d[:grouping])
        b.query = d[:query]
        b.default_allow_title = d[:type] != BadgeType::Bronze
        b.default_enabled = SWITCHES.fetch(d[:set]).call
        b.listable = true
        b.multiple_grant = false
        b.target_posts = false
        b.show_posts = false
        b.auto_revoke = d[:auto_revoke]
        b.trigger = Badge::Trigger::None
        b.system = true
      end
    end
  end

  # A set's switch or listing topics changed: follow its module's switch and
  # rebuild its queries.
  def self.refresh!(set)
    on = SWITCHES.fetch(set).call
    badges
      .select { |d| d[:set] == set }
      .each { |d| Badge.where(name: d[:name]).update_all(enabled: on, query: d[:query]) }
  end

  # Grant a set's badges now rather than at the daily badge run.
  def self.backfill_later(set)
    names = badges.select { |d| d[:set] == set }.map { |d| d[:name] }
    Badge
      .enabled
      .where(name: names)
      .pluck(:id)
      .each { |id| Jobs.enqueue(:backfill_badge, badge_id: id) }
  end

  # Published elections the member voted in. After publishing, ballots no
  # longer say whose they were; the voter's roll entry keeps a receipt
  # (Publisher.unlink_ballots!). Counted or set aside alike: whether a ballot
  # was set aside is the voter's own business, and a missing badge would
  # show it.
  def self.voted(times)
    <<~SQL
      SELECT v.user_id, MAX(e.published_at) granted_at
      FROM jtech_election_voters v
      JOIN jtech_elections e ON e.id = v.election_id
      WHERE e.status = #{election_status(:published)} AND v.receipt IS NOT NULL
        AND v.user_id IS NOT NULL
      GROUP BY v.user_id
      HAVING COUNT(DISTINCT e.id) >= #{times}
    SQL
  end

  # Candidates once nominations are over (from Vote Week on), never one taken
  # off the ballot. `elected` counts only published results.
  def self.candidates(statuses, elected: nil, times: 1)
    phases =
      if elected.nil?
        %i[voting closed published]
      else
        %i[published]
      end
    <<~SQL
      SELECT c.user_id, MAX(COALESCE(e.published_at, e.voting_open_at)) granted_at
      FROM jtech_election_candidates c
      JOIN jtech_elections e ON e.id = c.election_id
      WHERE c.user_id IS NOT NULL
        AND c.status IN (#{statuses.map { |s| DiscourseModElections::Candidate.statuses[s] }.join(",")})
        AND e.status IN (#{phases.map { |s| election_status(s) }.join(",")})
        #{elected.nil? ? "" : "AND c.elected = #{elected}"}
      GROUP BY c.user_id
      HAVING COUNT(DISTINCT e.id) >= #{times}
    SQL
  end

  def self.election_status(name)
    DiscourseModElections::Election.statuses.fetch(name)
  end

  # Anyone the staff log shows was ever made a moderator, elected or
  # appointed, who isn't one now (or an admin).
  def self.former_moderators
    <<~SQL
      SELECT h.target_user_id user_id, MAX(h.created_at) granted_at
      FROM user_histories h
      JOIN users u ON u.id = h.target_user_id
      WHERE h.action = #{UserHistory.actions[:grant_moderation]}
        AND NOT u.moderator AND NOT u.admin
      GROUP BY h.target_user_id
    SQL
  end

  def self.shared_with(people)
    <<~SQL
      SELECT owner_id user_id, MAX(created_at) granted_at
      FROM reqpm_shares
      GROUP BY owner_id
      HAVING COUNT(DISTINCT recipient_id) >= #{people}
    SQL
  end

  # Posts in the for-sale topics other than their opening posts, as
  # DiscourseListingFormat.listing? has it. Not core's badge_posts: an old
  # sale thread is often unlisted (archived) and its listings still count.
  # These badges never link to a post, so nothing in it is shown.
  def self.listings(count)
    <<~SQL
      SELECT p.user_id, MAX(p.created_at) granted_at
      FROM posts p
      WHERE #{listing_posts("p")}
      GROUP BY p.user_id
      HAVING COUNT(*) >= #{count}
    SQL
  end

  def self.listing_posts(posts)
    ids = DiscourseListingFormat::Checker.topic_ids.presence || [-1]
    <<~SQL.squish
      #{posts}.topic_id IN (#{ids.map(&:to_i).join(",")}) AND #{posts}.post_number > 1
      AND #{posts}.deleted_at IS NULL AND NOT #{posts}.hidden
      AND #{posts}.post_type = #{Post.types[:regular]}
    SQL
  end

  def self.dumbcourse_days(days)
    <<~SQL
      SELECT user_id, updated_at granted_at
      FROM user_custom_fields
      WHERE name = '#{DiscourseDumbcourse::Usage::DAYS_FIELD}'
        AND (CASE WHEN value ~ '^[0-9]+$' THEN value::int ELSE 0 END) >= #{days}
    SQL
  end

  def self.dumbcourse_posts(count)
    <<~SQL
      SELECT p.user_id, MAX(p.created_at) granted_at
      FROM badge_posts p
      JOIN post_custom_fields f ON f.post_id = p.id
      WHERE f.name = '#{DiscourseDumbcourse::Usage::POST_FIELD}' AND f.value = 't'
      GROUP BY p.user_id
      HAVING COUNT(*) >= #{count}
    SQL
  end

  def self.power_users
    names = POWER_USER_PARTS.map { |n| "'#{n}'" }.join(",")
    <<~SQL
      SELECT ub.user_id, MAX(ub.granted_at) granted_at
      FROM user_badges ub
      JOIN badges b ON b.id = ub.badge_id
      WHERE b.name IN (#{names})
      GROUP BY ub.user_id
      HAVING COUNT(DISTINCT b.id) = #{POWER_USER_PARTS.size}
    SQL
  end
end
