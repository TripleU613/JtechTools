# frozen_string_literal: true

module DiscourseModElections
  # The election in progress, cached: the current-user serializer asks on
  # every page load.
  module State
    CACHE_KEY = "jtech-mod-elections-active"

    # { id:, status:, ends_at:, extended: } for an election people can see
    # (nominations or later, not yet published or cancelled), or nil.
    # extended: nominations stay open longer for want of candidates.
    def self.active
      Discourse.cache.fetch(CACHE_KEY, expires_in: 5.minutes) { compute || false } || nil
    end

    def self.compute
      election = Election.where(status: %i[nominating voting closed]).order(:id).last
      return if election.nil?
      {
        id: election.id,
        status: election.status,
        ends_at: election.phase_ends_at&.iso8601,
        extended: election.nominations_extended?,
      }
    end

    CHANNEL = "/jtech-elections/state"

    # An election moved to its next step: drop the cache and tell open
    # elections pages to reload. Only that something changed goes out, to
    # signed-in members; the page asks the server for the rest.
    def self.changed!
      Discourse.cache.delete(CACHE_KEY)
      MessageBus.publish(
        CHANNEL,
        { changed: true },
        group_ids: [Group::AUTO_GROUPS[:trust_level_0]],
      )
    end
  end
end
