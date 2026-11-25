# frozen_string_literal: true

module DiscourseDiscordChat
  # Discord's Linked Roles flow: the member starts it from the server menu,
  # signs in here, approves the app on Discord, and comes back connected.
  # Connecting is all it does: the forum account gets the Discord account
  # linked (as the Discord login would), the server's sync then gives the
  # roles the forum allows, and the linked role itself grants nothing, so a
  # suspended member can't claim their way back in through Discord's menu.
  class LinkController < ::ApplicationController
    requires_plugin "jtech-tools"

    PLATFORM = "JTech Forums"
    STATE_KEY = "discord_chat_link_state"

    skip_before_action :check_xhr, :preload_json, :redirect_to_login_if_required
    before_action :ensure_linking_on

    def start
      if !current_user
        cookies[:destination_url] = request.fullpath
        return redirect_to path("/login")
      end

      state = SecureRandom.hex(16)
      server_session.set(STATE_KEY, state, expires: 10.minutes)
      query = {
        client_id: SiteSetting.discord_client_id.to_s.strip,
        redirect_uri: callback_url,
        response_type: "code",
        scope: "identify role_connections.write",
        state: state,
      }
      redirect_to "https://discord.com/oauth2/authorize?#{query.to_query}", allow_other_host: true
    end

    def callback
      if !current_user
        return finish("Sign in on the forum first, then start again from Discord.", 403)
      end

      expected = server_session[STATE_KEY]
      server_session.delete(STATE_KEY)
      if expected.blank? ||
           !ActiveSupport::SecurityUtils.secure_compare(expected, params[:state].to_s)
        return finish("That link expired. Start again from the server's Linked Roles menu.", 403)
      end
      return finish("Nothing was connected: Discord didn't approve it.") if params[:code].blank?

      api = Api.new
      token = api.exchange_code(params[:code], callback_url)["access_token"]
      me = api.user(:get, "/users/@me", token)
      discord_id = me["id"].to_s

      taken = UserAssociatedAccount.find_by(provider_name: "discord", provider_uid: discord_id)
      if taken && taken.user_id != current_user.id
        return finish("That Discord account is connected to a different forum account.", 409)
      end
      mine = UserAssociatedAccount.find_by(provider_name: "discord", user_id: current_user.id)
      if mine && mine.provider_uid != discord_id
        return(
          finish(
            "Your forum account is connected to a different Discord account. Disconnect it under Preferences → Account first.",
            409,
          )
        )
      end

      if !taken
        UserAssociatedAccount.create!(
          provider_name: "discord",
          provider_uid: discord_id,
          user: current_user,
          info: {
            "nickname" => me["username"],
            "name" => me["global_name"],
          },
          last_used: Time.zone.now,
        )
      end

      api.user(
        :put,
        "/users/@me/applications/#{SiteSetting.discord_client_id.to_s.strip}/role-connection",
        token,
        {
          platform_name: PLATFORM,
          platform_username: current_user.username,
          metadata: {
            linked: 1,
          },
        },
      )
      Jobs.enqueue(:discord_chat_sync_members)

      if DiscourseDiscordChat.allowed?(current_user)
        finish("Connected. Head back to Discord: the chat opens for you within a minute.")
      else
        finish(
          "Connected. The chat opens once your forum account reaches trust level #{SiteSetting.discord_chat_min_trust_level}: read around the forum a bit and it comes on its own.",
        )
      end
    rescue Api::Error => e
      Rails.logger.warn("#{DiscourseDiscordChat::LOG_TAG} link: #{e.message}")
      finish("Discord didn't answer. Try again in a minute.", 502)
    end

    private

    def ensure_linking_on
      raise Discourse::NotFound if !DiscourseDiscordChat.linked_roles_enabled?
    end

    def callback_url
      "#{Discourse.base_url}/discord-chat/link/callback"
    end

    def finish(message, status = 200)
      render plain: message, status: status
    end
  end
end
