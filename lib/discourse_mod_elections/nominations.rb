# frozen_string_literal: true

module DiscourseModElections
  # Getting on (and off) the ballot.
  module Nominations
    # Sitting moderators go on the ballot when nominations open. They can
    # drop out until nominations close. Returns their user ids, to tell them
    # once the change is saved.
    def self.add_incumbents!(election)
      ids = Seats.sitting.pluck(:id)
      return [] if ids.empty?
      now = Time.zone.now
      rows =
        ids.map do |user_id|
          {
            election_id: election.id,
            user_id: user_id,
            incumbent: true,
            status: Candidate.statuses[:running],
            created_at: now,
            updated_at: now,
          }
        end
      Candidate.insert_all(rows, unique_by: %i[election_id user_id])
      ids
    end

    # Under the election's lock, which opening the vote takes too, so the
    # ballot never changes once Vote Week has begun.
    def self.run!(user, election, statement)
      election.with_lock do
        reason = Eligibility.run_blocked_reason(user, election)
        raise Error.new(reason) if reason
        candidate = election.candidates.find_or_initialize_by(user_id: user.id)
        candidate.status = :running
        candidate.statement = clean(statement)
        save!(candidate)
      end
    end

    def self.update_statement!(user, election, statement)
      election.with_lock do
        raise Error.new(:not_nominating) unless election.taking_nominations?
        candidate = own_candidacy!(user, election)
        candidate.statement = clean(statement)
        save!(candidate)
      end
    end

    def self.withdraw!(user, election)
      election.with_lock do
        raise Error.new(:not_nominating) unless election.taking_nominations?
        own_candidacy!(user, election).update!(status: :withdrawn)
      end
    end

    # Under the election's lock, like publishing, so a count never sees a
    # candidate halfway on or off the ballot.
    def self.disqualify!(candidate, reason, actor)
      reason = reason.to_s.strip
      raise Error.new(:reason_required) if reason.blank?
      candidate.election.with_lock do
        raise Error.new(:finished) unless candidate.election.unfinished?
        candidate.update!(
          status: :disqualified,
          disqualified_reason: reason.truncate(500),
          disqualified_by: actor,
        )
      end
      StaffActionLogger.new(actor).log_custom(
        "mod_election_disqualify",
        target_user_id: candidate.user_id,
        election_id: candidate.election_id,
        reason: reason,
      )
      Notifier.notify([candidate.user_id].compact, candidate.election, "disqualified")
    end

    def self.reinstate!(candidate, actor)
      candidate.election.with_lock do
        raise Error.new(:finished) unless candidate.election.unfinished?
        raise Error.new(:not_found) unless candidate.reload.disqualified?
        candidate.update!(status: :running, disqualified_reason: nil, disqualified_by: nil)
      end
      StaffActionLogger.new(actor).log_custom(
        "mod_election_reinstate",
        target_user_id: candidate.user_id,
        election_id: candidate.election_id,
      )
    end

    # Someone leaving their seat mid-term also leaves the ballot of any
    # election still going: stepping down drops them out, and a moderator
    # removed for abuse is taken off with that as the reason, so winning it
    # can't hand them the seat straight back.
    # A deleted account can't take a seat, so it comes off every ballot still
    # open, and ballots that ranked it move on to their next choice. Once
    # voting has closed the count is left alone: the admin's preview lists
    # the winner who can't serve, and the admin decides.
    def self.drop_deleted!
      open = Election.where(status: %i[scheduled nominating voting])
      Candidate
        .running
        .where(user_id: nil, election_id: open.select(:id))
        .includes(:election)
        .find_each do |candidate|
          election = candidate.election
          election.with_lock do
            next unless election.scheduled? || election.nominating? || election.voting?
            candidate.update!(status: :withdrawn)
          end
        end
    end

    def self.leave_ballots!(user, seat_left_reason, actor)
      Candidate
        .running
        .where(user_id: user.id, election_id: Election.unfinished.select(:id))
        .includes(:election)
        .find_each do |candidate|
          if seat_left_reason == "removed"
            disqualify!(candidate, I18n.t("mod_elections.reasons.removed"), actor)
          else
            candidate.update!(status: :withdrawn)
          end
        end
    end

    def self.own_candidacy!(user, election)
      candidate = election.candidates.running.find_by(user_id: user.id)
      raise Error.new(:not_running) if candidate.nil?
      candidate
    end

    # Plain text: no HTML is ever rendered from it, but stray control
    # characters and runs of blank lines go.
    def self.clean(statement)
      statement.to_s.gsub(/\r\n?/, "\n").gsub(/[^\P{Cc}\n\t]/, "").gsub(/\n{3,}/, "\n\n").strip
    end

    def self.save!(candidate)
      max = SiteSetting.mod_elections_statement_max_length
      raise Error.new(:statement_too_long, max: max) if candidate.statement.length > max
      candidate.save!
      candidate
    end
  end
end
