# frozen_string_literal: true

module DiscourseModElections
  # The two steps staff act on, in the Telegram reports topic too when
  # Disteleplus is on and sends admin notices: voting has closed (check the
  # ballots and publish) and the results are out. Nothing about the count
  # before it's published (that chat can include moderators, who are
  # candidates), and nothing about anyone's ballot.
  module Disteleplus
    def self.available?
      ::DiscourseDisteleplus::Reports.admin_notices?
    end

    def self.closed(election)
      return unless available?
      notice(
        election,
        "closed",
        I18n.t(
          "mod_elections.telegram.closed",
          url: "#{Discourse.base_url}/admin/plugins/jtech-tools/mod-elections",
        ),
      )
    end

    def self.results(election)
      return unless available?
      names = Presenter.elected_usernames(election)
      notice(
        election,
        "results",
        I18n.t(
          "mod_elections.telegram.results",
          winners: escape(names.presence&.join(", ") || I18n.t("mod_elections.topic.nobody")),
          url: "#{Discourse.base_url}/elections?id=#{election.id}",
        ),
      )
    end

    def self.notice(election, step, text)
      send_html(
        "🗳 <b>#{escape(I18n.t("mod_elections.title"))}</b>\n#{text}",
        dedupe_key: "mod-election-#{election.id}-#{step}",
      )
    rescue StandardError => e
      Rails.logger.warn("#{DiscourseModElections::LOG_TAG} Telegram notice failed: #{e.message}")
    end

    def self.send_html(html, dedupe_key:)
      ::DiscourseDisteleplus::Reports.notify_admin_notice(html, dedupe_key: dedupe_key)
    end

    def self.escape(text)
      ::DiscourseDisteleplus::Reports.escape(text)
    end
  end
end
