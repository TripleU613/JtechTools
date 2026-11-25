# frozen_string_literal: true

require "rails_helper"

RSpec.describe Jobs::DiscordChatRegisterCommands do
  let(:calls) { [] }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discord_chat_enabled = true
    SiteSetting.discord_chat_bot_token = "bot-token"
    SiteSetting.discord_chat_guild_id = "7"
    SiteSetting.discord_client_id = "555"

    WebMock
      .stub_request(:any, %r{\Ahttps://discord\.com/api/v10/})
      .to_return do |request|
        calls << {
          method: request.method,
          path: request.uri.path.delete_prefix("/api/v10"),
          auth: request.headers["Authorization"],
          body: JSON.parse(request.body),
        }
        { status: 200, body: "[]", headers: { "Content-Type" => "application/json" } }
      end
  end

  it "puts every command in the server as the bot" do
    SiteSetting.discord_chat_commands_enabled = true
    described_class.new.execute({})

    expect(calls.size).to eq(1)
    call = calls.first
    expect(call[:method]).to eq(:put)
    expect(call[:path]).to eq("/applications/555/guilds/7/commands")
    expect(call[:auth]).to eq("Bot bot-token")
    expect(call[:body].map { |c| c["name"] }).to contain_exactly(
      "search",
      "guide",
      "rules",
      "whois",
      "leaderboard",
    )
    expect(call[:body]).to all(include("type" => 1))
    expect(call[:body].map { |c| c["description"].length }).to all(be_between(1, 100))

    search = call[:body].find { |c| c["name"] == "search" }
    expect(search["options"]).to eq(
      [{ "name" => "query", "description" => "What to look for", "type" => 3, "required" => true }],
    )
    whois = call[:body].find { |c| c["name"] == "whois" }
    expect(whois["options"].first).to include("name" => "user", "type" => 6, "required" => true)
  end

  it "adds the message menu's report entry when reports are on" do
    SiteSetting.discord_chat_commands_enabled = false
    SiteSetting.discord_chat_reports_enabled = true
    described_class.new.execute({})
    expect(calls.first[:body]).to eq([{ "name" => "Report to moderators", "type" => 3 }])
  end

  it "empties the server's command list when commands are off" do
    SiteSetting.discord_chat_commands_enabled = false
    described_class.new.execute({})
    expect(calls.first[:method]).to eq(:put)
    expect(calls.first[:body]).to eq([])
  end

  it "does nothing without the Discord login's client ID" do
    SiteSetting.discord_client_id = ""
    described_class.new.execute({})
    expect(calls).to be_empty
  end

  it "does nothing while the module is off" do
    SiteSetting.discord_chat_enabled = false
    described_class.new.execute({})
    expect(calls).to be_empty
  end

  it "is queued when commands are switched on" do
    expect_enqueued_with(job: :discord_chat_register_commands) do
      SiteSetting.discord_chat_commands_enabled = true
    end
  end

  it "is queued when the public key changes" do
    expect_enqueued_with(job: :discord_chat_register_commands) do
      SiteSetting.discord_chat_public_key = "ab" * 32
    end
  end
end
