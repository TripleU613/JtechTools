# frozen_string_literal: true

require "rails_helper"

RSpec.describe Jobs::DiscordChatReport do
  fab!(:reporter) { Fabricate(:user, username: "helper_forum") }
  fab!(:moderator)

  let(:calls) { [] }
  let(:args) do
    {
      reporter_id: "40",
      reporter_name: "helper",
      author_id: "41",
      author_name: "troll",
      channel_id: "300",
      message_id: "900",
      content: "hey @#{moderator.username} look ~~~ [link](https://evil.example)",
    }
  end

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discord_chat_enabled = true
    SiteSetting.discord_chat_bot_token = "bot-token"
    SiteSetting.discord_chat_guild_id = "7"
    SiteSetting.discord_chat_reports_enabled = true
    SiteSetting.discord_chat_mod_log_channel_id = "555"
    UserAssociatedAccount.create!(provider_name: "discord", provider_uid: "40", user: reporter)

    WebMock
      .stub_request(:any, %r{\Ahttps://discord\.com/api/v10/})
      .to_return do |request|
        calls << [request.uri.path.delete_prefix("/api/v10"), JSON.parse(request.body)]
        { status: 200, body: "{}", headers: { "Content-Type" => "application/json" } }
      end
  end

  it "messages the forum's moderators group with the text as a plain code block" do
    expect { described_class.new.execute(args) }.to change { Topic.private_messages.count }.by(1)
    topic = Topic.private_messages.last
    expect(topic.allowed_groups.map(&:id)).to eq([Group::AUTO_GROUPS[:moderators]])
    raw = topic.first_post.raw
    expect(raw).to include("https://discord.com/channels/7/300/900")
    expect(raw).to include("[helper_forum](#{reporter.full_url})")
    expect(raw).to include("troll (not linked)")
    expect(raw).to match(/~~~~text\n.*look ~~ \[link\]/m)
    expect(topic.first_post.cooked).not_to include("mention")
  end

  it "notifies nobody by name" do
    expect { described_class.new.execute(args) }.not_to change {
      Notification.where(user: moderator, notification_type: Notification.types[:mentioned]).count
    }
  end

  it "logs the report in the server without pinging anyone" do
    described_class.new.execute(args)
    path, body = calls.find { |p, _| p == "/channels/555/messages" }
    expect(path).to be_present
    expect(body["content"]).to include("<@40>", "<@41>", "<#300>", "> hey")
    expect(body["allowed_mentions"]).to eq({ "parse" => [] })
  end

  it "does nothing while reports are off" do
    SiteSetting.discord_chat_reports_enabled = false
    expect { described_class.new.execute(args) }.not_to change { Topic.count }
    expect(calls).to be_empty
  end
end
