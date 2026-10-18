# frozen_string_literal: true

module Jobs
  # "You can run" for every member who could, when nominations open and
  # again if they stay open for want of candidates.
  class ModElectionsInviteCandidates < ::Jobs::Base
    def execute(args)
      return unless DiscourseModElections.enabled?
      election = DiscourseModElections::Election.find_by(id: args[:election_id])
      return if election.nil? || !election.taking_nominations?
      ids = DiscourseModElections::Eligibility.could_run(election).select(:id)
      DiscourseModElections::Notifier.notify(ids, election, args[:kind].to_s)
    end
  end
end
