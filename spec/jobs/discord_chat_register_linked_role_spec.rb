# frozen_string_literal: true

require "rails_helper"

RSpec.describe Jobs::DiscordChatRegisterLinkedRole do
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
        calls << [
          request.method,
          request.uri.path.delete_prefix("/api/v10"),
          JSON.parse(request.body),
        ]
        { status: 200, body: "[]", headers: { "Content-Type" => "application/json" } }
      end
  end

  it "registers the one yes/no requirement as the bot" do
    SiteSetting.discord_chat_linked_roles_enabled = true
    described_class.new.execute({})
    method, path, body = calls.last
    expect([method, path]).to eq([:put, "/applications/555/role-connections/metadata"])
    expect(body).to eq(
      [
        {
          "type" => 7,
          "key" => "linked",
          "name" => "Linked to JTech Forums",
          "description" => "Has connected a JTech Forums account",
        },
      ],
    )
  end

  it "does nothing while the setting is off" do
    described_class.new.execute({})
    expect(calls).to be_empty
  end
end
