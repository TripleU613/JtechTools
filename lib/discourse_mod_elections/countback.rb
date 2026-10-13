# frozen_string_literal: true

module DiscourseModElections
  # Filling a seat someone left mid-term: count the same ballots again
  # without the people who left, and the first newly elected candidate
  # takes the seat. No new vote.
  module Countback
    # The election whose seats are being served now.
    def self.current_election
      Election.published.order(published_at: :desc).first
    end

    # The candidate who would take the seat, or nil when nobody is left.
    def self.replacement(election)
      excluded = election.candidates.where.not(seat_left_at: nil).pluck(:id)
      seated = election.candidates.seated.pluck(:id)
      loop do
        result = Tally.count(election, excluded: excluded)
        id = result.elected.find { |candidate_id| seated.exclude?(candidate_id) }
        return if id.nil?
        candidate = election.candidates.includes(:user).find(id)
        return candidate if eligible?(candidate.user)
        # Suspended, made an admin or already a moderator since: skip them
        # and count again.
        excluded << id
      end
    end

    def self.eligible?(user)
      Eligibility.can_serve?(user) && !user.moderator?
    end

    # Under the election's lock, so two clicks (or two admins) fill one seat
    # once.
    def self.fill!(election, actor)
      raise Error.new(:not_found) unless election == current_election
      candidate =
        election.with_lock do
          seats_open = election.seats - election.candidates.seated.count
          raise Error.new(:no_open_seat) if seats_open <= 0
          found = replacement(election)
          raise Error.new(:no_replacement) if found.nil?

          user = found.user
          StaffLog.log(actor, "mod_election_countback", user_id: user.id, election_id: election.id)
          user.grant_moderation!
          StaffActionLogger.new(actor).log_grant_moderation(user)
          Seats.seat_trust_level!(user, actor)
          found.update!(elected: true)

          result = election.result || {}
          result["countbacks"] = Array(result["countbacks"]) +
            [{ "candidate" => found.id, "at" => Time.zone.now.iso8601 }]
          election.update!(result: result)
          found
        end

      # The results page lists the countback: open ones reload.
      State.changed!
      Announcer.countback(election, candidate)
      Notifier.notify([candidate.user_id], election, "seat_filled")
      candidate
    end
  end
end
