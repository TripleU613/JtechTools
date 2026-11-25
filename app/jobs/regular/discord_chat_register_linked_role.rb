# frozen_string_literal: true

module Jobs
  # Tells Discord what the app's linked role can check: one yes/no, "linked
  # to JTech Forums". A server role then uses it under Links.
  class DiscordChatRegisterLinkedRole < ::Jobs::Base
    METADATA = [
      {
        type: 7,
        key: "linked",
        name: "Linked to JTech Forums",
        description: "Has connected a JTech Forums account",
      },
    ].freeze

    def execute(_args)
      return if !DiscourseDiscordChat.configured? || !DiscourseDiscordChat.linked_roles_enabled?
      application_id = SiteSetting.discord_client_id.to_s.strip
      return if application_id.blank?

      DiscourseDiscordChat::Api.new.bot(
        :put,
        "/applications/#{application_id}/role-connections/metadata",
        METADATA,
      )
    rescue DiscourseDiscordChat::Api::Error => e
      Rails.logger.warn("#{DiscourseDiscordChat::LOG_TAG} linked role: #{e.message}")
    end
  end
end
