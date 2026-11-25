# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseDiscordChat::Starboard do
  let(:calls) { [] }
  let(:messages) do
    {
      "300" => [
        message("1", stars: 3, content: "great @everyone"),
        message("2", stars: 2),
        message("3", stars: 5, bot: true),
        message("4", stars: 9, at: 10.days.ago),
      ],
      "666" => [message("5", stars: 9)],
    }
  end

  def message(id, stars:, content: "hi", bot: false, at: 1.hour.ago)
    {
      "id" => id,
      "content" => content,
      "timestamp" => at.iso8601,
      "author" => {
        "id" => "41",
        "username" => "moshe",
        "avatar" => "abc",
        "bot" => bot,
      },
      "reactions" => [{ "emoji" => { "name" => "⭐" }, "count" => stars }],
    }
  end

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discord_chat_enabled = true
    SiteSetting.discord_chat_bot_token = "bot-token"
    SiteSetting.discord_chat_guild_id = "7"
    SiteSetting.discord_chat_starboard_channel_id = "999"
    SiteSetting.discord_chat_starboard_channels = "300"
    SiteSetting.discord_chat_starboard_threshold = 3

    WebMock
      .stub_request(:any, %r{\Ahttps://discord\.com/api/v10/})
      .to_return do |request|
        path = request.uri.path.delete_prefix("/api/v10")
        calls << [request.method, path, request.body.presence && JSON.parse(request.body)]
        channel = path[%r{\A/channels/(\d+)/messages\z}, 1]
        body = request.method == :get ? messages.fetch(channel, []) : {}
        { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
      end
  end

  def reposts
    calls.select { |m, p, _| m == :post && p == "/channels/999/messages" }.map(&:last)
  end

  it "reposts a message once it has enough stars, and only once" do
    described_class.new.run
    described_class.new.run
    expect(reposts.size).to eq(1)
    repost = reposts.first
    expect(repost["content"]).to include("⭐ 3", "<#300>", "https://discord.com/channels/7/300/1")
    expect(repost["embeds"].first["description"]).to eq("great @everyone")
    expect(repost["allowed_mentions"]).to eq({ "parse" => [] })
  end

  it "skips bot messages, old messages and those under the threshold" do
    described_class.new.run
    expect(reposts.map { |r| r["content"] }).to all(include("/300/1"))
  end

  it "never reads a channel that isn't listed" do
    described_class.new.run
    expect(calls.map { |_, p, _| p }).not_to include("/channels/666/messages")
  end

  it "does nothing without a starboard channel" do
    SiteSetting.discord_chat_starboard_channel_id = ""
    described_class.new.run
    expect(calls).to be_empty
  end
end
