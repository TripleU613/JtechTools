# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseDiscordChat::MemberSync do
  fab!(:linked) { Fabricate(:user, username: "moshe") }
  fab!(:suspended) { Fabricate(:user, suspended_till: 1.week.from_now, suspended_at: 1.day.ago) }
  fab!(:moderator) { Fabricate(:moderator, username: "mod_yossi") }
  fab!(:owner) { Fabricate(:admin, username: "the_owner") }

  let(:calls) { [] }
  let(:members) do
    [
      member("10", roles: []),
      member("11", roles: ["50"]),
      member("12", roles: ["50"]),
      member("13", roles: []),
      member("1", roles: [], nick: nil),
      { "user" => { "id" => "99", "bot" => true }, "roles" => [] },
    ]
  end

  def member(id, roles:, nick: nil)
    { "user" => { "id" => id }, "roles" => roles, "nick" => nick }
  end

  def link(user, discord_id)
    UserAssociatedAccount.create!(provider_name: "discord", provider_uid: discord_id, user: user)
  end

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discord_chat_enabled = true
    SiteSetting.discord_chat_bot_token = "bot-token"
    SiteSetting.discord_chat_guild_id = "7"
    SiteSetting.discord_chat_member_role_id = "50"
    SiteSetting.discord_chat_moderator_role_id = "60"
    SiteSetting.discord_chat_admin_role_id = "70"

    link(linked, "10")
    link(suspended, "11")
    link(moderator, "13")
    link(owner, "1")

    WebMock
      .stub_request(:any, %r{\Ahttps://discord\.com/api/v10/})
      .to_return do |request|
        path = request.uri.path.delete_prefix("/api/v10")
        calls << [request.method, path, request.body.presence && JSON.parse(request.body)]
        body =
          case path
          when "/guilds/7"
            { "id" => "7", "owner_id" => "1" }
          when "/guilds/7/members"
            members
          when "/users/@me/channels"
            { "id" => "dm" }
          else
            {}
          end
        { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
      end
  end

  def role_calls(method)
    calls.select { |m, p, _| m == method && p.include?("/roles/") }.map { |_, p, _| p }
  end

  it "gives linked, allowed members the member role and staff the staff roles" do
    described_class.new.run
    expect(role_calls(:put)).to contain_exactly(
      "/guilds/7/members/10/roles/50",
      "/guilds/7/members/13/roles/50",
      "/guilds/7/members/13/roles/60",
      "/guilds/7/members/1/roles/50",
      "/guilds/7/members/1/roles/60",
      "/guilds/7/members/1/roles/70",
    )
  end

  it "takes the member role from the unlinked and the suspended" do
    described_class.new.run
    expect(role_calls(:delete)).to contain_exactly(
      "/guilds/7/members/11/roles/50",
      "/guilds/7/members/12/roles/50",
    )
  end

  it "names linked members after their forum account, but never the server's owner" do
    described_class.new.run
    renames = calls.select { |m, p, _| m == :patch && p.start_with?("/guilds/7/members/") }
    expect(renames.map { |_, p, b| [p, b["nick"]] }).to contain_exactly(
      %w[/guilds/7/members/10 moshe],
      %w[/guilds/7/members/13 mod_yossi],
    )
  end

  it "leaves nicknames alone when that's switched off" do
    SiteSetting.discord_chat_sync_nicknames = false
    described_class.new.run
    expect(calls.select { |m, _, _| m == :patch }).to be_empty
  end

  it "doesn't let a moderator's Discord account reach the admin role" do
    described_class.new.run
    expect(role_calls(:put)).not_to include("/guilds/7/members/13/roles/70")
  end

  it "takes access away from a member silenced on the forum" do
    members[0]["roles"] = ["50"]
    linked.update!(silenced_till: 1.week.from_now)
    described_class.new.run
    expect(role_calls(:delete)).to include("/guilds/7/members/10/roles/50")
  end

  it "keeps out members below the trust level floor, but never staff" do
    SiteSetting.discord_chat_min_trust_level = 2
    linked.update!(trust_level: TrustLevel[1])
    described_class.new.run
    expect(role_calls(:put)).not_to include("/guilds/7/members/10/roles/50")
    expect(role_calls(:put)).to include("/guilds/7/members/13/roles/50")
  end

  it "waits out a short rate limit instead of ending the run" do
    limited = 0
    WebMock
      .stub_request(:put, %r{/guilds/7/members/10/roles/50})
      .to_return do
        limited += 1
        if limited == 1
          {
            status: 429,
            body: { retry_after: 0.5 }.to_json,
            headers: {
              "Content-Type" => "application/json",
            },
          }
        else
          { status: 204, body: "" }
        end
      end
    waits = []
    described_class.new(sleeper: ->(seconds) { waits << seconds }).run
    expect(limited).to eq(2)
    expect(waits).to eq([1])
    expect(role_calls(:put)).to include("/guilds/7/members/13/roles/50")
  end

  it "gives up a run on a long rate limit, for the next run to finish" do
    WebMock.stub_request(:get, %r{/guilds/7/members}).to_return(
      status: 429,
      body: { retry_after: 60 }.to_json,
      headers: {
        "Content-Type" => "application/json",
      },
    )
    expect { described_class.new(sleeper: ->(_) {}).run }.to raise_error(
      DiscourseDiscordChat::Api::RateLimited,
    )
  end

  describe "roles for trust levels, groups and badges" do
    fab!(:helpers) { Fabricate(:group, name: "helpers") }
    fab!(:badge)

    before do
      linked.update!(trust_level: TrustLevel[2])
      helpers.add(linked)
      BadgeGranter.grant(badge, linked)
      SiteSetting.discord_chat_trust_level_roles = "1:81|2:82"
      SiteSetting.discord_chat_group_roles = "helpers:83"
      SiteSetting.discord_chat_badge_roles = "#{badge.id}:84"
    end

    it "gives the role for the current trust level, groups and badges" do
      described_class.new.run
      puts_for_10 = role_calls(:put).select { |p| p.start_with?("/guilds/7/members/10/") }
      expect(puts_for_10).to include(
        "/guilds/7/members/10/roles/82",
        "/guilds/7/members/10/roles/83",
        "/guilds/7/members/10/roles/84",
      )
      expect(puts_for_10).not_to include("/guilds/7/members/10/roles/81")
    end

    it "takes the role away once the member leaves the group" do
      members[0]["roles"] = %w[50 83]
      helpers.remove(linked)
      described_class.new.run
      expect(role_calls(:delete)).to include("/guilds/7/members/10/roles/83")
    end
  end

  describe "the Supporter role from the server shop" do
    fab!(:supporters) { Fabricate(:group, name: "supporters") }

    before do
      SiteSetting.discord_chat_supporter_role_id = "90"
      SiteSetting.discord_chat_supporter_group = "supporters"
    end

    it "adds a linked buyer to the forum group, and never removes them" do
      members[0]["roles"] = %w[90]
      described_class.new.run
      expect(supporters.reload.users).to include(linked)

      members[0]["roles"] = []
      described_class.new.run
      expect(supporters.reload.users).to include(linked)
    end

    it "doesn't touch the Supporter role on Discord" do
      members[0]["roles"] = %w[90]
      described_class.new.run
      expect(calls.map { |_, p, _| p }.grep(%r{/roles/90})).to be_empty
    end
  end

  describe "timeouts from forum restrictions" do
    before { SiteSetting.discord_chat_sync_timeouts = true }

    def timeout_calls
      calls.select { |m, _, body| m == :patch && body&.key?("communication_disabled_until") }
    end

    it "times a suspended member out until the suspension ends" do
      freeze_time
      described_class.new.run
      expect(timeout_calls.map { |_, p, _| p }).to eq(["/guilds/7/members/11"])
      until_time = Time.zone.parse(timeout_calls.first[2]["communication_disabled_until"])
      expect(until_time).to be_within(1.second).of(suspended.suspended_till)
    end

    it "caps the timeout at Discord's 28 days" do
      freeze_time
      suspended.update!(suspended_till: 1.year.from_now)
      described_class.new.run
      until_time = Time.zone.parse(timeout_calls.first[2]["communication_disabled_until"])
      expect(until_time).to be <= 28.days.from_now
    end

    it "leaves a timeout that is already about right alone" do
      members[1]["communication_disabled_until"] = (suspended.suspended_till - 1.hour).iso8601
      described_class.new.run
      expect(timeout_calls).to be_empty
    end

    it "lifts a timeout the forum set once the restriction ends" do
      described_class.new.run
      suspended.update!(suspended_till: nil, suspended_at: nil)
      members[1]["communication_disabled_until"] = 3.days.from_now.iso8601
      calls.clear
      described_class.new.run
      expect(timeout_calls).to eq(
        [[:patch, "/guilds/7/members/11", { "communication_disabled_until" => nil }]],
      )
    end

    it "never lifts a moderator's own timeout in the server" do
      members[0]["communication_disabled_until"] = 2.days.from_now.iso8601
      described_class.new.run
      expect(timeout_calls.map { |_, p, _| p }).not_to include("/guilds/7/members/10")
    end

    it "does nothing when the setting is off" do
      SiteSetting.discord_chat_sync_timeouts = false
      described_class.new.run
      expect(timeout_calls).to be_empty
    end
  end

  describe "the moderators' log" do
    before { SiteSetting.discord_chat_mod_log_channel_id = "555" }

    def log_lines
      calls.select { |m, p, _| m == :post && p == "/channels/555/messages" }.map { |_, _, b| b }
    end

    it "logs who got in and who lost access, without pinging anyone" do
      described_class.new.run
      texts = log_lines.map { |b| b["content"] }
      expect(texts).to include(a_string_including("<@10>", "moshe"))
      expect(texts).to include(a_string_including("<@11>", "lost access"))
      expect(log_lines.map { |b| b["allowed_mentions"] }.uniq).to eq([{ "parse" => [] }])
    end

    it "logs nothing without a channel" do
      SiteSetting.discord_chat_mod_log_channel_id = ""
      described_class.new.run
      expect(calls.map { |_, p, _| p }.grep(%r{/channels/})).to be_empty
    end
  end

  describe "the welcome message" do
    before do
      SiteSetting.discord_chat_welcome_message = "Hi {username}, start in #introductions!"
      members.each { |m| m["joined_at"] = 1.hour.ago.iso8601 }
    end

    def opened
      calls
        .select { |m, p, _| m == :post && p == "/users/@me/channels" }
        .map { |_, _, b| b["recipient_id"] }
    end

    it "welcomes each allowed member once" do
      described_class.new.run
      expect(opened).to contain_exactly("10", "13", "1")
      calls.clear
      described_class.new.run
      expect(opened).to be_empty
    end

    it "fills in the forum username and pings nobody" do
      described_class.new.run
      bodies =
        calls.select { |m, p, _| m == :post && p == "/channels/dm/messages" }.map { |_, _, b| b }
      expect(bodies.map { |b| b["content"] }).to include("Hi moshe, start in #introductions!")
      expect(bodies.map { |b| b["allowed_mentions"] }.uniq).to eq([{ "parse" => [] }])
    end

    it "skips the suspended and anyone who joined long ago" do
      members[0]["joined_at"] = 1.month.ago.iso8601
      described_class.new.run
      expect(opened).not_to include("10", "11")
    end

    it "sends nothing when the message is blank" do
      SiteSetting.discord_chat_welcome_message = ""
      described_class.new.run
      expect(opened).to be_empty
    end
  end
end
