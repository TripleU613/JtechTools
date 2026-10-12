# frozen_string_literal: true

module Jobs
  # Opens nominations, Vote Week and the count on time (writes also check
  # the clock, so a late run lets nothing slip in). Each step checks the
  # clock and the election's status, so a late or repeated run is harmless.
  class ModElectionsTick < ::Jobs::Scheduled
    every 1.minute

    def execute(_args)
      return unless DiscourseModElections.enabled?
      DiscourseModElections::Lifecycle.tick
    end
  end
end
