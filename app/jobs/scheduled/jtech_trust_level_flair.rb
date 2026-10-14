# frozen_string_literal: true

module Jobs
  # Gives members their trust level flair (DiscourseTrustLevelFlair). Daily
  # for everyone; enqueued with user_ids when a trust level changes or an
  # account is made, after core has moved them into their trust level group.
  class JtechTrustLevelFlair < ::Jobs::Scheduled
    every 1.day

    def execute(args)
      DiscourseTrustLevelFlair.sync!(user_ids: args[:user_ids])
    end
  end
end
