# frozen_string_literal: true

require "net/http"

module DiscourseDiscordChat
  # Net::HTTP wrapper over Discord's REST API, as the server's bot.
  class Api
    BASE = "https://discord.com/api/v10"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20

    class Error < StandardError
      attr_reader :status

      def initialize(status, message)
        @status = status
        super("Discord API #{status}: #{message}")
      end
    end

    class NotFound < Error
    end

    class RateLimited < Error
      attr_reader :retry_after

      def initialize(retry_after)
        @retry_after = [retry_after.to_f.ceil, 1].max
        super(429, "rate limited, retry after #{@retry_after}s")
      end
    end

    def initialize(token: nil)
      @token = token || SiteSetting.discord_chat_bot_token
    end

    def bot(method, path, body = nil, query: nil)
      request(method, path, body, query: query, auth: "Bot #{@token}")
    end

    # Interaction webhooks are authorised by the token in the path, so the
    # bot token stays out of these calls.
    def webhook(method, path, body = nil)
      request(method, path, body, query: nil)
    end

    private

    def request(method, path, body, query:, auth: nil)
      uri = URI("#{BASE}#{path}")
      uri.query = URI.encode_www_form(query) if query.present?
      klass = Net::HTTP.const_get(method.to_s.capitalize)
      req = klass.new(uri.request_uri)
      req["Authorization"] = auth if auth
      req["User-Agent"] = "DiscourseBot (https://github.com/TripleU613/JtechTools, 1.0)"
      if body
        req["Content-Type"] = "application/json"
        req.body = body.to_json
      end

      response =
        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: true,
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT,
        ) { |http| http.request(req) }

      parse(response)
    end

    def parse(response)
      status = response.code.to_i
      data = json(response.body)

      return data if status.between?(200, 299)

      if status == 429
        retry_after = data.is_a?(Hash) ? data["retry_after"] : response["Retry-After"]
        raise RateLimited.new(retry_after)
      end

      message = data.is_a?(Hash) ? data["message"] : response.body.to_s.truncate(200)
      raise NotFound.new(status, message) if status == 404
      raise Error.new(status, message)
    end

    def json(body)
      return nil if body.blank?
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end
  end
end
