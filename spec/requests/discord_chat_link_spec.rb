# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseDiscordChat::LinkController do
  fab!(:user) { Fabricate(:user, username: "moshe", trust_level: 1) }
  fab!(:other) { Fabricate(:user) }

  let(:calls) { [] }
  let(:discord_id) { "4242" }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discord_chat_enabled = true
    SiteSetting.discord_chat_bot_token = "bot-token"
    SiteSetting.discord_chat_guild_id = "7"
    SiteSetting.discord_chat_linked_roles_enabled = true
    SiteSetting.discord_client_id = "555"
    SiteSetting.discord_secret = "shh"

    WebMock
      .stub_request(:any, %r{\Ahttps://discord\.com/api/v10/})
      .to_return do |request|
        path = request.uri.path.delete_prefix("/api/v10")
        calls << [request.method, path, request.headers["Authorization"], request.body]
        body =
          case path
          when "/oauth2/token"
            { "access_token" => "user-token" }
          when "/users/@me"
            { "id" => discord_id, "username" => "moshe_dc" }
          else
            {}
          end
        { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
      end
  end

  def start
    get "/discord-chat/link"
    Rack::Utils.parse_query(URI(response.location).query)["state"]
  end

  it "sends someone who isn't signed in to log in first" do
    get "/discord-chat/link"
    expect(response).to redirect_to("/login")
  end

  it "sends a signed-in member to Discord's authorize page" do
    sign_in(user)
    get "/discord-chat/link"
    location = URI(response.location)
    expect(location.host).to eq("discord.com")
    query = Rack::Utils.parse_query(location.query)
    expect(query).to include(
      "client_id" => "555",
      "scope" => "identify role_connections.write",
      "redirect_uri" => "#{Discourse.base_url}/discord-chat/link/callback",
    )
    expect(query["state"]).to be_present
  end

  it "connects the accounts, records the role connection and runs the sync" do
    sign_in(user)
    state = start
    expect_enqueued_with(job: :discord_chat_sync_members) do
      get "/discord-chat/link/callback", params: { state: state, code: "abc" }
    end
    expect(response.status).to eq(200)
    expect(response.body).to include("Connected")
    link = UserAssociatedAccount.find_by(provider_name: "discord", provider_uid: discord_id)
    expect(link.user).to eq(user)

    token_call = calls.find { |_, p, _, _| p == "/oauth2/token" }
    expect(token_call[3]).to include("client_secret=shh", "code=abc")
    role = calls.find { |_, p, _, _| p == "/users/@me/applications/555/role-connection" }
    expect(role[2]).to eq("Bearer user-token")
    expect(JSON.parse(role[3])).to include(
      "platform_username" => "moshe",
      "metadata" => {
        "linked" => 1,
      },
    )
  end

  it "refuses a wrong or reused state" do
    sign_in(user)
    state = start
    get "/discord-chat/link/callback", params: { state: "nope", code: "abc" }
    expect(response.status).to eq(403)
    get "/discord-chat/link/callback", params: { state: state, code: "abc" }
    expect(response.status).to eq(403)
    expect(UserAssociatedAccount.count).to eq(0)
  end

  it "won't take a Discord account already connected to someone else" do
    UserAssociatedAccount.create!(provider_name: "discord", provider_uid: discord_id, user: other)
    sign_in(user)
    get "/discord-chat/link/callback", params: { state: start, code: "abc" }
    expect(response.status).to eq(409)
    expect(UserAssociatedAccount.where(user: user)).to be_empty
  end

  it "won't swap the Discord account a forum account already has" do
    UserAssociatedAccount.create!(provider_name: "discord", provider_uid: "1111", user: user)
    sign_in(user)
    get "/discord-chat/link/callback", params: { state: start, code: "abc" }
    expect(response.status).to eq(409)
    expect(UserAssociatedAccount.find_by(user: user).provider_uid).to eq("1111")
  end

  it "links nothing for a callback while signed out" do
    get "/discord-chat/link/callback", params: { state: "x", code: "abc" }
    expect(response.status).to eq(403)
    expect(UserAssociatedAccount.count).to eq(0)
    expect(calls).to be_empty
  end

  it "links nothing when the member cancels on Discord" do
    sign_in(user)
    get "/discord-chat/link/callback", params: { state: start, error: "access_denied" }
    expect(response.status).to eq(200)
    expect(UserAssociatedAccount.count).to eq(0)
    expect(calls).to be_empty
  end

  it "is not there while the setting is off" do
    SiteSetting.discord_chat_linked_roles_enabled = false
    sign_in(user)
    get "/discord-chat/link"
    expect(response.status).to eq(404)
  end
end
