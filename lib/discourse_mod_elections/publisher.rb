# frozen_string_literal: true

module DiscourseModElections
  # Publishing the count: results go up and moderator rights follow them.
  module Publisher
    # What publishing would do, for the admin to check first. The first
    # preview fixes the ballots: one set aside between two previews would
    # show, in the difference, what was on it.
    def self.preview(election)
      election.with_lock do
        raise Error.new(:not_closed) unless election.closed?
        election.update!(previewed_at: Time.zone.now) if election.previewed_at.nil?
      end
      result = Tally.count(election)
      { result: Tally.serialize(election, result), plan: Seats.plan(election, result.elected) }
    end

    def self.publish!(election, actor)
      election.with_lock do
        raise Error.new(:not_closed) unless election.closed?
        result = Tally.count(election)
        # Nobody voted in a contested election: publishing would only remove
        # the sitting moderators. Cancel it instead.
        raise Error.new(:no_votes) if result.outcome == :no_votes

        plan = Seats.plan(election, result.elected)
        if plan[:problems].any?
          names = plan[:problems].map { |c| c.user&.username || "##{c.id}" }.join(", ")
          raise Error.new(:winners_cannot_serve, names: names)
        end

        election.candidates.where(id: result.elected).update_all(elected: true)
        Seats.apply!(plan, actor)
        unlink_ballots!(election)
        election.update!(
          status: :published,
          result: Tally.serialize(election, result),
          published_at: Time.zone.now,
          published_by: actor,
        )
        StaffLog.log(actor, "mod_election_publish", election_id: election.id)
      end
      # Announced once the results are saved, so a failed post can't undo
      # them.
      State.changed!
      Announcer.results(election)
      Notifier.notify(election.candidates.running.pluck(:user_id), election, "results")
      Disteleplus.results(election)
      election
    end

    # Ballots were tied to accounts only so nobody voted twice. Once the
    # count is final, each voter's roll entry keeps what became of their
    # ballot, and the ballots keep only what the count and a countback need:
    # no user, no address, no time anyone voted. A ballot set aside isn't
    # counted, so its ranking goes too.
    def self.unlink_ballots!(election)
      ballots = election.ballots.where.not(user_id: nil)
      counted = ballots.counted.pluck(:user_id)
      election.voters.where(user_id: counted).update_all(receipt: "counted")
      ballots
        .where.not(voided_at: nil)
        .pluck(:user_id, :void_reason)
        .each do |user_id, reason|
          election
            .voters
            .where(user_id: user_id)
            .update_all(receipt: "set_aside", receipt_reason: reason)
        end
      now = Time.zone.now
      election.ballots.where.not(voided_at: nil).update_all(ranking: [], void_reason: nil)
      election.ballots.update_all(
        user_id: nil,
        ip_address: nil,
        voided_by_id: nil,
        created_at: now,
        updated_at: now,
      )
    end

    def self.cancel!(election, actor)
      election.with_lock do
        raise Error.new(:finished) unless election.unfinished?
        election.update!(status: :cancelled)
        # Nothing will ever be counted: the ballots go.
        election.ballots.delete_all
      end
      StaffLog.log(actor, "mod_election_cancel", election_id: election.id)
      State.changed!
      Announcer.cancelled(election)
      election
    end
  end
end
