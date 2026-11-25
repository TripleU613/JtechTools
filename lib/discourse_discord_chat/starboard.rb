# frozen_string_literal: true

module DiscourseDiscordChat
  # Reposts messages that collected enough ⭐ reactions into the starboard
  # channel. Only the channels listed in the setting are read, so a starred
  # message in a private channel the bot can see never reaches members.
  class Starboard
    STAR = "⭐"
    LOOKBACK = 50
    MAX_AGE = 7.days
    STORE = MemberSync::STORE

    def initialize(api: Api.new)
      @api = api
    end

    def run
      target = SiteSetting.discord_chat_starboard_channel_id.to_s.strip
      return if target.blank?

      sources.each do |channel_id|
        next if channel_id == target
        messages = @api.bot(:get, "/channels/#{channel_id}/messages", query: { limit: LOOKBACK })
        starred = Array(messages).select { |message| qualifies?(message) }
        next if starred.empty?

        keys = starred.map { |message| key(message["id"]) }
        done = PluginStoreRow.where(plugin_name: STORE, key: keys).pluck(:key).to_set
        starred.each do |message|
          next if done.include?(key(message["id"]))
          PluginStore.set(STORE, key(message["id"]), true)
          @api.bot(:post, "/channels/#{target}/messages", repost(message, channel_id))
        end
      end
    end

    private

    def sources
      SiteSetting.discord_chat_starboard_channels.to_s.split("|").map(&:strip).reject(&:blank?)
    end

    def qualifies?(message)
      return false if message.dig("author", "bot")
      sent = Time.zone.parse(message["timestamp"].to_s)
      return false if sent.nil? || sent < MAX_AGE.ago
      stars(message) >= SiteSetting.discord_chat_starboard_threshold
    end

    def stars(message)
      reaction = Array(message["reactions"]).find { |r| r.dig("emoji", "name") == STAR }
      reaction ? reaction["count"].to_i : 0
    end

    def key(message_id)
      "starred_#{message_id}"
    end

    def repost(message, channel_id)
      guild = SiteSetting.discord_chat_guild_id.to_s.strip
      link = "https://discord.com/channels/#{guild}/#{channel_id}/#{message["id"]}"
      author = message["author"] || {}
      embed = {
        author: {
          name: (author["global_name"].presence || author["username"]).to_s.truncate(256),
          icon_url: avatar(author),
        }.compact,
        description: message["content"].to_s.truncate(4000),
        timestamp: message["timestamp"],
      }
      image =
        Array(message["attachments"]).find { |a| a["content_type"].to_s.start_with?("image/") }
      embed[:image] = { url: image["url"] } if image

      {
        content: "#{STAR} #{stars(message)} · <##{channel_id}> · #{link}",
        embeds: [embed],
        allowed_mentions: {
          parse: [],
        },
      }
    end

    def avatar(author)
      return if author["id"].blank? || author["avatar"].blank?
      "https://cdn.discordapp.com/avatars/#{author["id"]}/#{author["avatar"]}.png"
    end
  end
end
