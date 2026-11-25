# frozen_string_literal: true

module DiscourseDiscordChat
  # Answers the server's slash commands. Everything is looked up as a
  # logged-out visitor (Guardian.new), so a command can never show Discord
  # more than the public forum does: no private categories, messages,
  # whispers, hidden posts or unlisted topics.
  module Commands
    PING = 1
    APPLICATION_COMMAND = 2

    PONG = 1
    MESSAGE = 4
    DEFERRED_MESSAGE = 5

    EPHEMERAL = 64
    ANSWER_DELAY = 2.seconds
    CHAT_INPUT = 1
    MESSAGE_COMMAND = 3
    STRING = 3
    USER = 6

    RESULT_LIMIT = 5
    MAX_CONTENT = 2000
    TITLE_LENGTH = 100

    NOT_LINKED = "Not linked to a JTech account."

    REPORT = "Report to moderators"
    REPORTS_PER_HOUR = 5
    REPORT_LENGTH = 1500

    # Right-click a message → Apps. Message commands take no description.
    REPORT_DEFINITION = { name: REPORT, type: MESSAGE_COMMAND }.freeze

    DEFINITIONS = [
      {
        name: "search",
        type: CHAT_INPUT,
        description: "Search the forum",
        options: [{ name: "query", description: "What to look for", type: STRING, required: true }],
      },
      {
        name: "guide",
        type: CHAT_INPUT,
        description: "Find a guide",
        options: [
          { name: "topic", description: "What the guide is about", type: STRING, required: true },
        ],
      },
      { name: "rules", type: CHAT_INPUT, description: "Link to the forum rules" },
      {
        name: "whois",
        type: CHAT_INPUT,
        description: "Show a member's forum account",
        options: [{ name: "user", description: "Discord member", type: USER, required: true }],
      },
      { name: "leaderboard", type: CHAT_INPUT, description: "Top members on the forum" },
    ].freeze

    # What the server's command list should hold right now.
    def self.definitions
      list = []
      list.concat(DEFINITIONS) if SiteSetting.discord_chat_commands_enabled
      list << REPORT_DEFINITION if SiteSetting.discord_chat_reports_enabled
      list
    end

    def self.respond(interaction)
      case interaction["type"]
      when PING
        { type: PONG }
      when APPLICATION_COMMAND
        command(interaction)
      else
        reply("Unknown command.", ephemeral: true)
      end
    end

    def self.command(interaction)
      data = interaction["data"].is_a?(Hash) ? interaction["data"] : {}
      return report(interaction, data) if data["type"] == MESSAGE_COMMAND && data["name"] == REPORT
      return reply("Commands are off.", ephemeral: true) if !DiscourseDiscordChat.commands_enabled?

      case data["name"]
      when "search"
        defer("search", option(data, "query"), interaction)
      when "guide"
        defer("guide", option(data, "topic"), interaction)
      when "rules"
        reply(rules)
      when "whois"
        reply(whois(option(data, "user")))
      when "leaderboard"
        reply(leaderboard)
      else
        reply("Unknown command.", ephemeral: true)
      end
    end

    # Takes the reported message as Discord resolved it, answers the reporter
    # straight away (only they see it), and leaves the posting to a job.
    def self.report(interaction, data)
      return reply("Reports are off.", ephemeral: true) if !DiscourseDiscordChat.reports_enabled?
      if interaction["guild_id"].to_s != SiteSetting.discord_chat_guild_id.to_s.strip
        return reply("Reports only work in the JTech server.", ephemeral: true)
      end

      message = data.dig("resolved", "messages", data["target_id"].to_s)
      reporter = interaction.dig("member", "user")
      if !message.is_a?(Hash) || !reporter.is_a?(Hash)
        return reply("That message can't be reported.", ephemeral: true)
      end

      begin
        RateLimiter.new(
          nil,
          "discord_chat_report_#{reporter["id"]}",
          REPORTS_PER_HOUR,
          1.hour,
        ).performed!
      rescue RateLimiter::LimitExceeded
        return reply("That's a lot of reports. Try again in a while.", ephemeral: true)
      end

      author = message["author"].is_a?(Hash) ? message["author"] : {}
      Jobs.enqueue(
        :discord_chat_report,
        reporter_id: reporter["id"].to_s,
        reporter_name: reporter["username"].to_s,
        author_id: author["id"].to_s,
        author_name: author["username"].to_s,
        channel_id: (message["channel_id"] || interaction["channel_id"]).to_s,
        message_id: message["id"].to_s,
        content: message["content"].to_s.truncate(REPORT_LENGTH),
      )
      reply("Sent to the moderators. Thanks.", ephemeral: true)
    end

    # Search can take longer than the 3 seconds Discord waits for an answer,
    # so it runs in a job that edits the "thinking" message afterwards. The
    # job waits a moment: run straight away it reached Discord before this
    # response had, and there was no message to edit yet.
    def self.defer(kind, term, interaction)
      Jobs.enqueue_in(
        ANSWER_DELAY,
        :discord_chat_answer_command,
        kind: kind,
        term: term.to_s,
        application_id: interaction["application_id"].to_s,
        token: interaction["token"].to_s,
      )
      { type: DEFERRED_MESSAGE }
    end

    def self.reply(content, ephemeral: false)
      data = message(content)
      data[:flags] = EPHEMERAL if ephemeral
      { type: MESSAGE, data: data }
    end

    # Nobody gets pinged by a command, whatever a title or username says.
    def self.message(content)
      { content: content.to_s.truncate(MAX_CONTENT), allowed_mentions: { parse: [] } }
    end

    def self.deferred_answer(kind, term)
      case kind
      when "search"
        search(term)
      when "guide"
        guide(term)
      else
        "Unknown command."
      end
    end

    def self.search(term)
      topics = find_topics(term)
      return "Nothing found for #{quoted(term)}." if topics.empty?
      topics.map { |topic| link(topic) }.join("\n")
    end

    def self.guide(term)
      category = Category.find_by(slug: "guides", parent_category_id: nil)
      return "No guides found for #{quoted(term)}." if category.nil?
      return "No guides found for #{quoted(term)}." if !Guardian.new.can_see_category?(category)

      topics = find_topics(term, category)
      return "No guides found for #{quoted(term)}." if topics.empty?
      topics.map { |topic| link(topic) }.join("\n")
    end

    def self.rules
      "Forum rules: <#{Discourse.base_url}/guidelines>"
    end

    def self.whois(discord_id)
      # On a login-required forum a logged-out visitor sees no profiles.
      return NOT_LINKED if discord_id.blank? || SiteSetting.login_required

      user =
        UserAssociatedAccount
          .includes(user: %i[user_option user_stat])
          .find_by(provider_name: "discord", provider_uid: discord_id.to_s)
          &.user

      # Hidden, staged, suspended and unlinked all read the same, so the
      # reply never tells someone which of those it is.
      return NOT_LINKED if !DiscourseDiscordChat.allowed?(user)
      return NOT_LINKED if !Guardian.new.can_see_profile?(user)

      joined = user.created_at.strftime("%-d %B %Y")
      "**#{escape(user.username)}** · #{TrustLevel.name(user.trust_level)} · joined #{joined}\n<#{user.full_url}>"
    end

    def self.leaderboard
      url = "#{Discourse.base_url}/leaderboard"
      scores = leaderboard_scores
      return "Leaderboard: <#{url}>" if scores.empty?

      lines =
        scores.map { |user| "#{user.position}. #{escape(user.username)} — #{user.total_score}" }
      lines << "<#{url}>"
      lines.join("\n")
    end

    def self.leaderboard_scores
      return [] if SiteSetting.login_required
      return [] if !defined?(::DiscourseGamification::GamificationLeaderboard)
      return [] if !SiteSetting.respond_to?(:discourse_gamification_enabled)
      return [] if !SiteSetting.discourse_gamification_enabled

      board = ::DiscourseGamification::GamificationLeaderboard.first
      return [] if board.nil? || !Guardian.new.can_see_leaderboard?(board)

      ::DiscourseGamification::GamificationLeaderboard.scores_for(
        board.id,
        period: board.resolve_period(nil),
        user_limit: RESULT_LIMIT,
      ).to_a
    rescue ::DiscourseGamification::LeaderboardCachedView::NotReadyError
      []
    end

    def self.find_topics(term, category = nil)
      # Core search ignores login_required, so a logged-out search there
      # would show more than the forum shows a logged-out visitor.
      return [] if term.blank? || SiteSetting.login_required

      guardian = Guardian.new
      results =
        Search.new(
          term,
          guardian: guardian,
          type_filter: "topic",
          search_context: category,
          exclude_private_messages: true,
        ).execute

      Array(results&.posts)
        .map(&:topic)
        .compact
        .uniq
        .select { |topic| topic.visible && !topic.private_message? && guardian.can_see?(topic) }
        .first(RESULT_LIMIT)
    rescue Discourse::InvalidAccess
      # Filters such as in:messages need a login.
      []
    end

    def self.link(topic)
      "- [#{escape(topic.title.to_s.truncate(TITLE_LENGTH))}](<#{topic.url}>)"
    end

    def self.quoted(term)
      "“#{escape(term.to_s.truncate(TITLE_LENGTH))}”"
    end

    def self.escape(text)
      text.to_s.gsub(/\s+/, " ").gsub(/[\\*_~`|\[\]()<>]/) { |char| "\\#{char}" }
    end

    def self.option(data, name)
      found = Array(data["options"]).find { |opt| opt.is_a?(Hash) && opt["name"] == name }
      found && found["value"]
    end
  end
end
