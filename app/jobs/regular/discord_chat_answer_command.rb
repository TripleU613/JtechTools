# frozen_string_literal: true

module Jobs
  # Sends the answer to a deferred slash command by editing the "thinking"
  # message Discord shows. The interaction token is only good for 15
  # minutes, so a failed edit isn't retried.
  class DiscordChatAnswerCommand < ::Jobs::Base
    sidekiq_options retry: false

    def execute(args)
      content =
        if DiscourseDiscordChat.commands_enabled?
          answer(args[:kind], args[:term])
        else
          "Commands are off."
        end

      DiscourseDiscordChat::Api.new.webhook(
        :patch,
        "/webhooks/#{args[:application_id]}/#{args[:token]}/messages/@original",
        DiscourseDiscordChat::Commands.message(content),
      )
    rescue DiscourseDiscordChat::Api::Error => e
      Rails.logger.warn("#{DiscourseDiscordChat::LOG_TAG} command answer: #{e.message}")
    end

    private

    # Whatever goes wrong, the member still gets an answer instead of a
    # message stuck on "thinking".
    def answer(kind, term)
      DiscourseDiscordChat::Commands.deferred_answer(kind, term)
    rescue StandardError => e
      Rails.logger.warn("#{DiscourseDiscordChat::LOG_TAG} #{kind}: #{e.class}: #{e.message}")
      "Search failed. Try again in a minute."
    end
  end
end
