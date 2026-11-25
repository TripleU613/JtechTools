# frozen_string_literal: true

module Jobs
  # A message reported in the Discord server: a line in the moderators' log
  # there, and a message to the forum's moderators group, where moderators
  # already work. The reported text is untrusted, so it goes in as a code
  # block on the forum (no mentions, links or formatting) and pings nobody
  # in the server.
  class DiscordChatReport < ::Jobs::Base
    def execute(args)
      return if !DiscourseDiscordChat.configured? || !DiscourseDiscordChat.reports_enabled?

      guild = SiteSetting.discord_chat_guild_id.to_s.strip
      link = "https://discord.com/channels/#{guild}/#{args[:channel_id]}/#{args[:message_id]}"
      content = args[:content].to_s

      DiscourseDiscordChat::ModLog.post(
        "🚩 <@#{args[:reporter_id]}> reported a message by <@#{args[:author_id]}> in <##{args[:channel_id]}>: #{link}\n" +
          content.lines.first(10).map { |line| "> #{line.chomp}" }.join("\n"),
      )

      moderators = Group.find_by(id: Group::AUTO_GROUPS[:moderators])
      return if moderators.nil?

      PostCreator.create!(
        Discourse.system_user,
        title: "Server report: a message by #{plain(args[:author_name])}",
        raw: forum_body(args, link, content),
        archetype: Archetype.private_message,
        target_group_names: [moderators.name],
        skip_validations: true,
      )
    end

    private

    def forum_body(args, link, content)
      fence = "~~~~"
      <<~MD
        A message in the JTech server was reported.

        - **Reported by:** #{who(args[:reporter_id], args[:reporter_name])}
        - **Written by:** #{who(args[:author_id], args[:author_name])}
        - **Message:** #{link}

        #{fence}text
        #{content.gsub(/~{3,}/, "~~")}
        #{fence}
      MD
    end

    # The server name, plus the forum account when it's linked, as a profile
    # link rather than an @mention so nobody is notified.
    def who(discord_id, discord_name)
      user =
        UserAssociatedAccount.find_by(provider_name: "discord", provider_uid: discord_id.to_s)&.user
      name = plain(discord_name)
      user ? "#{name} (forum: [#{user.username}](#{user.full_url}))" : "#{name} (not linked)"
    end

    def plain(text)
      text.to_s.gsub(/[^\w.\- ]/, "").strip.truncate(40).presence || "unknown"
    end
  end
end
