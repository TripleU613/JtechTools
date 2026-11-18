# frozen_string_literal: true

module DiscourseJtechAds
  # A member's thumbs up or down on an ad they can see. value 1 or -1 sets
  # it; 0 takes it back.
  class VotesController < ::ApplicationController
    requires_plugin "jtech-tools"

    before_action :ensure_logged_in

    def update
      raise Discourse::NotFound unless DiscourseJtechAds.enabled?

      key = params.require(:key).to_s
      raise Discourse::NotFound unless DiscourseJtechAds.visible?(guardian, key)

      value = params.require(:value).to_i
      raise Discourse::InvalidParameters.new(:value) if [0, *VOTE_VALUES].exclude?(value)

      RateLimiter.new(current_user, "jtech-ad-vote", 30, 1.minute).performed!

      if value.zero?
        Vote.where(user_id: current_user.id, ad_key: key).delete_all
      else
        Vote.upsert(
          {
            user_id: current_user.id,
            ad_key: key,
            value: value,
            updated_at: Time.zone.now,
            created_at: Time.zone.now,
          },
          unique_by: %i[user_id ad_key],
          update_only: %i[value],
        )
      end

      result = { v: value.zero? ? nil : value }
      result[:n] = Vote.counts([key])[key] || { up: 0, down: 0 } if guardian.is_staff?
      render json: result
    end
  end
end
