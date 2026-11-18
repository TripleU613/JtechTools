# frozen_string_literal: true

require_relative "../lib/discourse_market_accounts"

after_initialize do
  register_user_custom_field_type(DiscourseMarketAccounts::FIELD, :boolean)

  reloadable_patch do
    ::SecondFactor::Actions::DiscourseConnectProvider.prepend(
      DiscourseMarketAccounts::ProviderExtension,
    )
  end

  register_modifier(:clean_up_inactive_users_query) do |scope|
    DiscourseMarketAccounts.cleanup_scope(scope)
  end
end
