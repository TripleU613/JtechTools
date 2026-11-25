# frozen_string_literal: true

require "rails_helper"

# Discord's Interactions Endpoint: only requests signed with the app's key
# get an answer, PING must be answered for Discord to accept the URL, and
# every command reply is built so nobody gets pinged.
RSpec.describe "Discord chat interactions" do
  let(:path) { "/discord-chat/interactions" }
  let(:signing_key) { OpenSSL::PKey.generate_key("ED25519") }
  let(:timestamp) { "1700000000" }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discord_chat_enabled = true
    SiteSetting.discord_chat_commands_enabled = true
    SiteSetting.discord_chat_public_key = signing_key.raw_public_key.unpack1("H*")
  end

  def sign(body, key: signing_key)
    key.sign(nil, timestamp + body).unpack1("H*")
  end

  def interact(payload, signature: :valid)
    body = payload.to_json
    headers = { "CONTENT_TYPE" => "application/json", "X-Signature-Timestamp" => timestamp }
    signature = sign(body) if signature == :valid
    headers["X-Signature-Ed25519"] = signature if signature
    post path, params: body, headers: headers
  end

  def command(name, options = [], extra = {})
    {
      type: 2,
      application_id: "555",
      token: "interaction-token",
      guild_id: "7",
      data: {
        name: name,
        type: 1,
        options: options,
      },
    }.merge(extra)
  end

  def reply
    response.parsed_body
  end

  describe "signature" do
    it "answers a correctly signed request" do
      interact({ type: 1 })
      expect(response.status).to eq(200)
    end

    it "401s when the signature is from another key" do
      other = OpenSSL::PKey.generate_key("ED25519")
      interact({ type: 1 }, signature: sign({ type: 1 }.to_json, key: other))
      expect(response.status).to eq(401)
    end

    it "401s when the body was changed after signing" do
      body = { type: 2, data: { name: "rules" } }.to_json
      post path,
           params: { type: 1 }.to_json,
           headers: {
             "CONTENT_TYPE" => "application/json",
             "X-Signature-Timestamp" => timestamp,
             "X-Signature-Ed25519" => sign(body),
           }
      expect(response.status).to eq(401)
    end

    it "401s when the signature is missing" do
      interact({ type: 1 }, signature: nil)
      expect(response.status).to eq(401)
    end

    it "401s when the signature isn't hex" do
      interact({ type: 1 }, signature: "zz" * 64)
      expect(response.status).to eq(401)
    end

    it "401s when no public key is set, so it is never open by accident" do
      SiteSetting.discord_chat_public_key = ""
      interact({ type: 1 })
      expect(response.status).to eq(401)
    end

    it "404s while the whole bundle is off" do
      SiteSetting.jtech_enabled = false
      interact({ type: 1 })
      expect(response.status).to eq(404)
    end
  end

  describe "PING" do
    it "answers PONG" do
      interact({ type: 1 })
      expect(reply).to eq("type" => 1)
    end

    it "answers PONG while commands are off, so the URL can be set first" do
      SiteSetting.discord_chat_commands_enabled = false
      interact({ type: 1 })
      expect(reply).to eq("type" => 1)
    end
  end

  describe "switches" do
    it "says commands are off, only to the caller, when commands are off" do
      SiteSetting.discord_chat_commands_enabled = false
      interact(command("rules"))
      expect(reply["type"]).to eq(4)
      expect(reply["data"]["content"]).to eq("Commands are off.")
      expect(reply["data"]["flags"]).to eq(64)
    end

    it "says commands are off when the module is off" do
      SiteSetting.discord_chat_enabled = false
      interact(command("rules"))
      expect(reply["data"]["content"]).to eq("Commands are off.")
      expect(reply["data"]["flags"]).to eq(64)
    end

    it "doesn't queue a search while commands are off" do
      SiteSetting.discord_chat_commands_enabled = false
      expect {
        interact(command("search", [{ name: "query", type: 3, value: "x" }]))
      }.not_to change { Jobs::DiscordChatAnswerCommand.jobs.size }
    end
  end

  it "answers an unknown command only to the caller" do
    interact(command("launch"))
    expect(reply["data"]["content"]).to eq("Unknown command.")
    expect(reply["data"]["flags"]).to eq(64)
  end

  it "rejects a signed body that isn't an interaction" do
    body = "[1]"
    post path,
         params: body,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "X-Signature-Timestamp" => timestamp,
           "X-Signature-Ed25519" => sign(body),
         }
    expect(response.status).to eq(400)
  end

  describe "/search" do
    it "defers and queues the search with what the follow-up needs" do
      expect_enqueued_with(
        job: :discord_chat_answer_command,
        args: {
          kind: "search",
          term: "android",
          application_id: "555",
          token: "interaction-token",
        },
      ) { interact(command("search", [{ name: "query", type: 3, value: "android" }])) }
      expect(reply).to eq("type" => 5)
    end
  end

  describe "/guide" do
    it "defers and queues the guide search" do
      expect_enqueued_with(
        job: :discord_chat_answer_command,
        args: {
          kind: "guide",
          term: "flashing",
        },
      ) { interact(command("guide", [{ name: "topic", type: 3, value: "flashing" }])) }
      expect(reply).to eq("type" => 5)
    end
  end

  describe "/rules" do
    it "links the guidelines and pings nobody" do
      interact(command("rules"))
      expect(reply["type"]).to eq(4)
      expect(reply["data"]["content"]).to include("#{Discourse.base_url}/guidelines")
      expect(reply["data"]["allowed_mentions"]).to eq("parse" => [])
      expect(reply["data"]).not_to have_key("flags")
    end
  end

  describe "/whois" do
    fab!(:member) { Fabricate(:user, username: "moshe", trust_level: TrustLevel[2]) }

    before do
      UserAssociatedAccount.create!(provider_name: "discord", provider_uid: "42", user: member)
    end

    it "shows the linked forum account" do
      interact(command("whois", [{ name: "user", type: 6, value: "42" }]))
      content = reply["data"]["content"]
      expect(content).to include("moshe")
      expect(content).to include(TrustLevel.name(2))
      expect(content).to include(member.full_url)
      expect(reply["data"]["allowed_mentions"]).to eq("parse" => [])
    end

    it "says not linked for a Discord user without an account" do
      interact(command("whois", [{ name: "user", type: 6, value: "43" }]))
      expect(reply["data"]["content"]).to eq("Not linked to a JTech account.")
    end

    it "says nothing about someone who hid their profile" do
      member.user_option.update!(hide_profile: true)
      interact(command("whois", [{ name: "user", type: 6, value: "42" }]))
      expect(reply["data"]["content"]).to eq("Not linked to a JTech account.")
      expect(reply["data"]["content"]).not_to include("moshe")
    end
  end

  describe "/leaderboard" do
    it "links the leaderboard when Gamification is off" do
      SiteSetting.discourse_gamification_enabled = false
      interact(command("leaderboard"))
      expect(reply["data"]["content"]).to eq("Leaderboard: <#{Discourse.base_url}/leaderboard>")
    end
  end
end
