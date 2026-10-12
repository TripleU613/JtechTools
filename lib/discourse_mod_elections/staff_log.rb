# frozen_string_literal: true

module DiscourseModElections
  # The staff action log. Core's log_custom keeps everything but a few
  # columns as text, so the person an entry is about goes in its own column
  # here and the log can be filtered by them.
  module StaffLog
    def self.log(actor, type, user_id: nil, **details)
      UserHistory.create!(
        action: UserHistory.actions[:custom_staff],
        custom_type: type,
        acting_user_id: actor.id,
        target_user_id: user_id,
        details: details.map { |key, value| "#{key}: #{value.to_s.truncate(500)}" }.join("\n"),
      )
    end
  end
end
