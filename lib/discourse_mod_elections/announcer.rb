# frozen_string_literal: true

module DiscourseModElections
  # The election's topic: opened when nominations open, then a post for
  # Vote Week, the results and anything that changes a seat. Posted by the
  # system user. Without a category set, there's no topic.
  module Announcer
    def self.nominations_open(election)
      return if election.topic_id.present?
      category = Category.find_by(id: SiteSetting.mod_elections_category.to_i)
      return if category.nil?
      post =
        PostCreator.create!(
          Discourse.system_user,
          title: I18n.t("mod_elections.topic.title", month: election.month_label),
          raw: I18n.t("mod_elections.topic.nominations_open", **dates(election), url: page_url),
          category: category.id,
          skip_validations: true,
        )
      election.update!(topic_id: post.topic_id)
    rescue StandardError => e
      log(e)
    end

    def self.nominations_extended(election)
      reply(
        election,
        I18n.t("mod_elections.topic.nominations_extended", **dates(election), url: page_url),
      )
    end

    def self.vote_skipped(election)
      names = election.candidates.running.includes(:user).map { |c| "- #{user_link(c.user)}" }
      raw =
        if names.empty?
          I18n.t("mod_elections.topic.vote_skipped_nobody")
        else
          I18n.t("mod_elections.topic.vote_skipped", candidates: names.join("\n"))
        end
      reply(election, raw)
    end

    def self.voting_open(election)
      names = election.candidates.running.includes(:user).map { |c| user_link(c.user) }
      names = [I18n.t("mod_elections.topic.nobody")] if names.empty?
      reply(
        election,
        I18n.t(
          "mod_elections.topic.voting_open",
          **dates(election),
          candidates: names.map { |name| "- #{name}" }.join("\n"),
          url: page_url,
        ),
      )
    end

    def self.results(election)
      lines = Presenter.elected_usernames(election).map { |name| "- #{user_link_for(name)}" }
      lines = [I18n.t("mod_elections.topic.nobody")] if lines.empty?
      reply(
        election,
        I18n.t(
          "mod_elections.topic.results",
          winners: lines.join("\n"),
          ballots: election.result&.dig("ballots").to_i,
          url: "#{page_url}?id=#{election.id}",
        ),
      )
    end

    # An admin changed the seats or the dates still ahead: everyone hears the
    # new ones, so nobody plans around the old.
    def self.changed(election)
      key = election.voting? ? "changed_voting" : "changed"
      reply(
        election,
        I18n.t("mod_elections.topic.#{key}", count: election.seats, **dates(election)),
      )
    end

    def self.cancelled(election)
      reply(election, I18n.t("mod_elections.topic.cancelled"))
    end

    def self.countback(election, candidate)
      reply(election, I18n.t("mod_elections.topic.countback", user: user_link(candidate.user)))
    end

    def self.reply(election, raw)
      return if election.topic_id.blank? || !Topic.exists?(id: election.topic_id)
      PostCreator.create!(
        Discourse.system_user,
        topic_id: election.topic_id,
        raw: raw,
        skip_validations: true,
      )
    rescue StandardError => e
      log(e)
    end

    # A link, not an @mention: listing the candidates shouldn't notify them.
    def self.user_link(user)
      user_link_for(user&.username)
    end

    def self.user_link_for(username)
      return I18n.t("mod_elections.topic.deleted_user") if username.blank?
      "[#{username}](#{Discourse.base_path}/u/#{UrlHelper.encode_component(username)})"
    end

    def self.page_url
      "#{Discourse.base_url}/elections"
    end

    def self.dates(election)
      { voting_open: date(election.voting_open_at), voting_close: date(election.voting_close_at) }
    end

    # Shown in each reader's own time zone when local dates are on.
    def self.date(time)
      local = time.in_time_zone(Schedule.zone)
      if SiteSetting.respond_to?(:discourse_local_dates_enabled) &&
           SiteSetting.discourse_local_dates_enabled
        %([date=#{local.strftime("%Y-%m-%d")} time=#{local.strftime("%H:%M:%S")} timezone="#{Schedule.zone.tzinfo.name}"])
      else
        "#{I18n.l(local, format: :long)} (#{Schedule.zone.tzinfo.name})"
      end
    end

    def self.log(error)
      Rails.logger.warn("#{DiscourseModElections::LOG_TAG} announcement failed: #{error.message}")
    end
  end
end
