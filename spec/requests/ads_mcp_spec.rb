# frozen_string_literal: true

require "rails_helper"

# The ads' MCP tools, called the way an agent calls them
RSpec.describe "Ads MCP tools", if: defined?(DiscourseMcp) do
  fab!(:admin)
  fab!(:member, :user)
  fab!(:group)

  TOOLS = %w[jtech_ads_get jtech_ads_configure jtech_ads_save jtech_ads_delete jtech_ads_preview]

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.mcp_server_enabled = true
    SiteSetting.jtech_ads_list = "[]"
    TOOLS.each do |identifier|
      McpPrimitive.find_or_create_by!(kind: "tool", identifier:) { it.enabled = true }
    end
  end

  def authorize(user)
    group.add(user)
    [
      DiscourseMcp::INITIAL_SCOPE,
      DiscourseJtechAds::McpTools::READ_SCOPE,
      DiscourseJtechAds::McpTools::WRITE_SCOPE,
    ].each { |scope| McpGroupScope.find_or_create_by!(group:, scope:) }
    client =
      McpOauthClient.create!(
        client_id: SecureRandom.hex,
        name: "Ads test client",
        registration_type: "pre_registered",
        trust_state: "approved",
        redirect_uris: ["http://127.0.0.1/callback"],
      )
    authorization =
      DiscourseMcp::OAuth::AuthorizationGrant.create!(
        user:,
        client:,
        redirect_uri: client.redirect_uris.first,
        requested_scopes: McpGroupScope.where(group:).pluck(:scope),
      )
    @token = McpOauthAccessToken.issue!(authorization:)
  end

  def call(name, arguments = {})
    post "/mcp",
         params: {
           jsonrpc: "2.0",
           id: 1,
           method: "tools/call",
           params: {
             name:,
             arguments:,
           },
         }.to_json,
         headers: {
           "HTTP_AUTHORIZATION" => "Bearer #{@token}",
           "CONTENT_TYPE" => "application/json",
           "HTTP_ACCEPT" => "application/json, text/event-stream",
           "HTTP_MCP_PROTOCOL_VERSION" => DiscourseMcp::LEGACY_PROTOCOL_VERSION,
         }
    response.parsed_body["result"]
  end

  it "lets an admin set up ads end to end" do
    authorize(admin)

    configured = call("jtech_ads_configure", { enabled: true, rotate_seconds: 45 })
    expect(configured["structuredContent"]["settings"]).to include(
      "enabled" => true,
      "rotate_seconds" => 45,
    )

    saved =
      call(
        "jtech_ads_save",
        {
          name: "spring",
          headline: "Spring sale",
          card: %(<h2 class="jl-title nope">Spring</h2>),
          audience: "members",
        },
      )[
        "structuredContent"
      ]
    expect(saved["shows_as"]["card"]).to eq(%(<h2 class="jl-title">Spring</h2>))
    expect(saved["shows_as"]["dropped"]).to include("class nope")
    expect(saved["preview"]["url"]).to include("jl_preview=")

    listed = call("jtech_ads_get")["structuredContent"]
    expect(listed["ads"].map { it["name"] }).to eq(["spring"])
    expect(listed["kit"]["classes"]).to include("jl-split", "jl-button")

    draft = call("jtech_ads_preview", { name: "next", headline: "Next" })["structuredContent"]
    expect(DiscourseJtechAds::Manager.preview_line(draft["preview"]["token"])).to include(h: "Next")

    call("jtech_ads_delete", { name: "spring" })
    expect(JSON.parse(SiteSetting.jtech_ads_list)).to eq([])
  end

  it "refuses a member" do
    authorize(member)
    result = call("jtech_ads_get")
    expect(result.nil? || result["isError"]).to be_truthy
    expect(SiteSetting.jtech_ads_list).to eq("[]")
  end
end
