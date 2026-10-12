# frozen_string_literal: true

module DiscourseReqpm
  # Shared gate for every REQ-PM endpoint.
  #
  # Only a person's own browser session gets in. API keys (which an admin
  # can mint for any username) and admin impersonation are refused, so no
  # staff member can read someone's card or the details shared with them by
  # acting as that user.
  class BaseController < ::ApplicationController
    requires_plugin "jtech-tools"
    # Not `requires_login`: core stores that per class, so it would not
    # carry over to the controllers inheriting from this one.
    before_action :ensure_logged_in
    before_action :ensure_enabled
    before_action :ensure_own_session
    before_action :ensure_can_use
    after_action :no_store

    rescue_from Exchange::Error do |e|
      render_json_error(
        I18n.t("reqpm.errors.#{e.reason}", **error_params(e)),
        status: error_status(e.reason),
        extras: {
          reason: e.reason,
          retry_at: e.details[:retry_at],
          field: e.details[:field],
        }.compact,
      )
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless DiscourseReqpm.enabled?
    end

    def ensure_own_session
      raise Discourse::InvalidAccess.new(I18n.t("reqpm.errors.own_session_only")) if api_request?
      if current_user.is_impersonating
        raise Discourse::InvalidAccess.new(I18n.t("reqpm.errors.own_session_only"))
      end
    end

    def api_request?
      is_api? || is_user_api?
    end

    def ensure_can_use
      unless Policy.can_use?(current_user)
        raise Discourse::InvalidAccess.new(I18n.t("reqpm.errors.not_allowed"))
      end
    end

    # Contact details never sit in a browser or proxy cache.
    def no_store
      response.headers["Cache-Control"] = "no-store"
    end

    def exchange
      @exchange ||= Exchange.new(current_user)
    end

    def find_user!(username)
      user = User.find_by_username(username.to_s)
      raise Discourse::NotFound if user.nil? || user.id.to_i <= 0
      user
    end

    def error_status(reason)
      case reason
      when :not_found
        404
      when :cooldown, :pending
        429
      else
        422
      end
    end

    def error_params(error)
      params = error.details.except(:field, :problem, :retry_at)
      if error.reason == :invalid_field
        params[:problem] = I18n.t(
          "reqpm.errors.problems.#{error.details[:problem]}",
          field: I18n.t("reqpm.errors.fields.#{error.details[:field]}"),
        )
      end
      if error.details[:retry_at]
        params[:date] = I18n.l(error.details[:retry_at].to_date, format: :long)
      end
      params
    end
  end
end
