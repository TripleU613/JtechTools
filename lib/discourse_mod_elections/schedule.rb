# frozen_string_literal: true

module DiscourseModElections
  # The calendar from the settings: nominations open at midnight on the 1st
  # of each scheduled month in the configured zone, Vote Week follows them.
  module Schedule
    def self.zone
      ActiveSupport::TimeZone[SiteSetting.mod_elections_timezone.to_s] ||
        ActiveSupport::TimeZone["UTC"]
    end

    def self.months
      SiteSetting
        .mod_elections_schedule_months_map
        .map(&:to_i)
        .select { |month| (1..12).cover?(month) }
        .uniq
        .sort
    end

    # Phase dates for an election whose nominations open at `opens_at`.
    # Days are calendar days in the zone, so a clock change doesn't move
    # midnight.
    def self.dates_from(opens_at)
      opens_at = opens_at.in_time_zone(zone)
      voting_open_at = opens_at + SiteSetting.mod_elections_nomination_days.days
      {
        nominations_open_at: opens_at,
        voting_open_at: voting_open_at,
        voting_close_at: voting_open_at + SiteSetting.mod_elections_voting_days.days,
      }
    end

    # Dates of the scheduled election that should be running at `now`, or
    # nil between elections.
    def self.slot_at(now)
      local = now.in_time_zone(zone)
      return if months.exclude?(local.month)
      dates = dates_from(zone.local(local.year, local.month, 1))
      dates if now >= dates[:nominations_open_at] && now < dates[:voting_close_at]
    end

    # When nominations next open, for the admin tab.
    def self.next_opening(now = Time.zone.now)
      return if months.empty?
      start = now.in_time_zone(zone).beginning_of_month
      (0..12).each do |offset|
        month = start + offset.months
        next if months.exclude?(month.month)
        opens_at = zone.local(month.year, month.month, 1)
        return opens_at if opens_at > now
      end
      nil
    end
  end
end
