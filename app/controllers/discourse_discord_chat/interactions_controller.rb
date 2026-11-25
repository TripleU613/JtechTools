# frozen_string_literal: true

module DiscourseDiscordChat
  # Discord's Interactions Endpoint URL: slash commands arrive here as signed
  # POSTs with no session. The Ed25519 signature is the only authentication,
  # and Discord's own checks send bad ones on purpose, expecting a 401.
  class InteractionsController < ::ApplicationController
    requires_plugin "jtech-tools"

    skip_before_action :verify_authenticity_token,
                       :redirect_to_login_if_required,
                       :check_xhr,
                       :preload_json

    def create
      body = request.raw_post
      verified =
        DiscourseDiscordChat::Signature.valid?(
          public_key: SiteSetting.discord_chat_public_key,
          signature: request.headers["X-Signature-Ed25519"],
          timestamp: request.headers["X-Signature-Timestamp"],
          body: body,
        )
      if !verified
        return render json: { error: "Invalid request signature." }, status: :unauthorized
      end

      interaction =
        begin
          JSON.parse(body)
        rescue JSON::ParserError
          nil
        end
      if !interaction.is_a?(Hash)
        return render json: { error: "Request body is not an interaction." }, status: :bad_request
      end

      render json: DiscourseDiscordChat::Commands.respond(interaction)
    end
  end
end
