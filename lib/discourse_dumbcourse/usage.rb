# frozen_string_literal: true

module DiscourseDumbcourse
  # What its badges need to know: on how many days a member opened
  # Dumbcourse (user custom fields: the count, and the last day counted, in
  # UTC) and which posts were written in it (a post custom field, from the
  # `dumbcourse` flag its composer sends with a new post).
  module Usage
    DAYS_FIELD = "dumbcourse_days"
    LAST_DAY_FIELD = "dumbcourse_last_day"
    POST_FIELD = "dumbcourse"

    def self.visit!(user, today: Time.zone.now.utc.to_date)
      day = today.iso8601
      return if user.custom_fields[LAST_DAY_FIELD] == day
      user.custom_fields[LAST_DAY_FIELD] = day
      user.custom_fields[DAYS_FIELD] = user.custom_fields[DAYS_FIELD].to_i + 1
      user.save_custom_fields
    end

    def self.mark_post!(post)
      post.custom_fields[POST_FIELD] = true
      post.save_custom_fields
    end
  end
end
