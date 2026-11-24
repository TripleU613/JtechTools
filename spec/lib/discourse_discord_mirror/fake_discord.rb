# frozen_string_literal: true

# A stand-in for Discord's REST API: records every call and answers like
# Discord would for the endpoints the mirror uses.
class FakeDiscord
  Call = Struct.new(:method, :path, :query, :body)

  attr_reader :calls

  def initialize
    @calls = []
    @next_id = 1000
  end

  def install
    WebMock
      .stub_request(:any, %r{\Ahttps://discord\.com/api/v10/})
      .to_return do |request|
        uri = request.uri
        path = uri.path.delete_prefix("/api/v10")
        query = Rack::Utils.parse_query(uri.query.to_s)
        body = request.body.present? ? JSON.parse(request.body) : nil
        @calls << Call.new(request.method, path, query, body)
        respond(request.method, path, query, body)
      end
    self
  end

  def find(method, pattern)
    @calls.select { |c| c.method == method && c.path.match?(pattern) }
  end

  def reset
    @calls.clear
  end

  private

  def id
    (@next_id += 1).to_s
  end

  def json(data, status: 200)
    { status: status, body: data.to_json, headers: { "Content-Type" => "application/json" } }
  end

  def respond(method, path, query, body)
    case [method, path]
    in [:post, %r{\A/guilds/\d+/channels\z}]
      json({ "id" => id, "type" => body["type"], "name" => body["name"] })
    in [:post, %r{\A/channels/(\d+)/webhooks\z}]
      json({ "id" => id, "token" => "hook-token-#{id}" })
    in [:post, %r{\A/webhooks/\d+/[^/]+\z}]
      thread = query["thread_id"] || id
      json({ "id" => id, "channel_id" => thread })
    in [:patch, _] | [:delete, _]
      method == :delete ? { status: 204, body: "" } : json({ "id" => "1" })
    else
      json({ "message" => "unexpected #{method} #{path}" }, status: 400)
    end
  end
end
