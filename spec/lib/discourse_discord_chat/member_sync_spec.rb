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
end
