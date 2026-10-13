# frozen_string_literal: true

module DiscourseModElections
  # Publishing the count: results go up and moderator rights follow them.
  module Publisher
    # What publishing would do, for the admin to check first. The first
    # preview fixes the ballots: one set aside between two previews would
    # show, in the difference, what was on it.
    def self.preview(election)
      election.change_in!(:closed) do
        election.update!(previewed_at: Time.zone.now) if election.previewed_at.nil?
      end
      result = Tally.count(election)
      { result: Tally.serialize(election, result), plan: Seats.plan(election, result.elected) }
    end

    def self.publish!(election, actor)
      election.change_in!(:closed) do
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
      DB.exec(<<~SQL, election_id: election.id)
        UPDATE jtech_election_voters v
        SET receipt = CASE WHEN b.voided_at IS NULL THEN 'counted' ELSE 'set_aside' END,
            receipt_reason = b.void_reason
        FROM jtech_election_ballots b
        WHERE v.election_id = :election_id
          AND b.election_id = :election_id
          AND b.user_id = v.user_id
      SQL
      # Written again under new ids in a random order: the address report
      # showed admins each ballot's id beside its voter, so keeping the ids
      # (or the order they were cast in) would tie a ranking to its voter.
      DB.exec(<<~SQL, election_id: election.id, now: Time.zone.now)
        WITH old AS (
          DELETE FROM jtech_election_ballots
          WHERE election_id = :election_id
          RETURNING election_id, weight, ranking, voided_at
        )
        INSERT INTO jtech_election_ballots
          (election_id, weight, ranking, voided_at, created_at, updated_at)
        SELECT election_id,
               weight,
               CASE WHEN voided_at IS NULL THEN ranking ELSE '{}' END,
               voided_at,
               :now,
               :now
        FROM old
        ORDER BY random()
      SQL
    end

    def self.cancel!(election, actor)
      election.change_in!(:unfinished) do
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
