# frozen_string_literal: true

module ::DiscourseMarketAccounts
  FIELD = "jtech_market_account"
  CALLBACK_PATH = "/api/v1/auth/discourse/callback"

  def self.enabled?
    SiteSetting.jtech_enabled && SiteSetting.jtech_market_account_retention
  end

  def self.market_callback?(url)
    actual = URI.parse(url.to_s)
    expected = URI.parse(SiteSetting.jtech_market_origin)
    actual.scheme == "https" && actual.host == expected.host && actual.port == expected.port &&
      actual.path == CALLBACK_PATH && actual.userinfo.nil? && actual.fragment.nil?
  rescue URI::InvalidURIError
    false
  end

  def self.protect!(user)
    return unless enabled? && user
    return if UserCustomField.exists?(user_id: user.id, name: FIELD, value: "true")

    UserCustomField.find_or_initialize_by(user_id: user.id, name: FIELD).update!(value: "true")
  end

  def self.cleanup_scope(scope)
    return scope unless enabled?

    scope.where.not(id: UserCustomField.where(name: FIELD, value: "true").select(:user_id))
  end

  # Core has already verified the application's SSO signature before reaching
  # this method, including the second-factor paths. Never mark from raw query params.
  module ProviderExtension
    private

    def populate_user_data(sso)
      super
      if DiscourseMarketAccounts.enabled? &&
           DiscourseMarketAccounts.market_callback?(sso.return_sso_url)
        DiscourseMarketAccounts.protect!(current_user)
      end
    end
  end
end
