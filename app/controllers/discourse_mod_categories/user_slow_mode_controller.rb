# frozen_string_literal: true

module DiscourseModCategories
  # Puts a user in slow mode, or lifts it, from their admin page.
  class UserSlowModeController < BaseController
    requires_login
    before_action :ensure_module_enabled
    before_action { ensure_feature!(:mod_user_slow_mode_enabled) }

    # The current user's own slow mode, for their composer after a post.
    def show
      render json: { slow_mode: current_user.staff? ? nil : UserSlowMode.summary_for(current_user) }
    end

    def update
      user = find_user!

      seconds = params[:seconds].to_i
      if seconds % 1.minute.to_i != 0 || !seconds.between?(UserSlowMode::MIN_SECONDS, UserSlowMode::MAX_SECONDS)
        return render_json_error(I18n.t("discourse_mod_categories.slow_mode.errors.interval"))
      end

      ends_at = nil
      if params[:ends_at].present?
        ends_at = UserSlowMode.parse_time(params[:ends_at])
        if ends_at.nil? || ends_at <= Time.zone.now
          return render_json_error(I18n.t("discourse_mod_categories.slow_mode.errors.ends_at"))
        end
      end

      reason = params[:reason].to_s.strip
      if reason.blank?
        return render_json_error(I18n.t("discourse_mod_categories.slow_mode.errors.reason"))
      end
      if reason.length > UserSlowMode::REASON_MAX_LENGTH
        return(
          render_json_error(
            I18n.t(
              "discourse_mod_categories.slow_mode.errors.reason_too_long",
              count: UserSlowMode::REASON_MAX_LENGTH,
            ),
          )
        )
      end

      UserSlowMode.set!(user, actor: current_user, seconds: seconds, ends_at: ends_at, reason: reason)
      render json: { slow_mode: UserSlowMode.admin_summary_for(user) }
    end

    def destroy
      user = find_user!
      UserSlowMode.lift!(user, actor: current_user) if UserSlowMode.state_for(user)
      render json: { slow_mode: nil }
    end

    private

    def find_user!
      user = User.find_by(id: params[:user_id])
      raise Discourse::NotFound if user.nil?
      guardian.ensure_can_see!(user)
      raise Discourse::InvalidAccess unless guardian.can_set_user_slow_mode?(user)
      user
    end
  end
end
