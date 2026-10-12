# frozen_string_literal: true

module DiscourseModElections
  # Publishing the count: results go up and moderator rights follow them.
  module Publisher
    # What publishing would do, for the admin to check first.
    def self.preview(election)
      raise Error.new(:not_closed) unless election.closed?
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
        # The addresses were only kept for the alt-account check.
        election.ballots.update_all(ip_address: nil)
        election.update!(
          status: :published,
          result: Tally.serialize(election, result),
          published_at: Time.zone.now,
          published_by: actor,
        )
      end
      # Announced once the results are saved, so a failed post can't undo
      # them.
      State.changed!
      Announcer.results(election)
      Notifier.notify(election.candidates.running.pluck(:user_id), election, "results")
      Disteleplus.results(election)
      election
    end

    def self.cancel!(election, actor)
      election.with_lock do
        raise Error.new(:finished) unless election.unfinished?
        election.update!(status: :cancelled)
        election.ballots.update_all(ip_address: nil)
      end
      StaffActionLogger.new(actor).log_custom("mod_election_cancel", election_id: election.id)
      State.changed!
      Announcer.cancelled(election)
      election
    end
  end
end
