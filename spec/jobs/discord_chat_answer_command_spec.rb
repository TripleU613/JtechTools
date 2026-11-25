# frozen_string_literal: true

require "rails_helper"

RSpec.describe Jobs::DiscordChatAnswerCommand do
  fab!(:public_topic) { Fabricate(:topic, title: "Public zebracorn topic here") }

  let(:calls) { [] }
  let(:args) do
    { kind: "search", term: "zebracorn", application_id: "555", token: "interaction-token" }
  end

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discord_chat_enabled = true
    SiteSetting.discord_chat_commands_enabled = true
    SiteSetting.discord_chat_bot_token = "bot-token"

    SearchIndexer.enable
    SearchIndexer.with_indexing do
      Fabricate(:post, topic: public_topic, raw: "zebracorn public body text")
    end

    WebMock
      .stub_request(:any, %r{\Ahttps://discord\.com/api/v10/})
      .to_return do |request|
        calls << {
          method: request.method,
          path: request.uri.path.delete_prefix("/api/v10"),
          auth: request.headers["Authorization"],
          body: JSON.parse(request.body),
        }
        { status: 200, body: "{}", headers: { "Content-Type" => "application/json" } }
      end
  end

  it "edits the original response with the results, without the bot token" do
    described_class.new.execute(args)

    expect(calls.size).to eq(1)
    call = calls.first
    expect(call[:method]).to eq(:patch)
    expect(call[:path]).to eq("/webhooks/555/interaction-token/messages/@original")
    expect(call[:auth]).to be_nil
    expect(call[:body]["content"]).to include("(<#{public_topic.url}>)")
    expect(call[:body]["allowed_mentions"]).to eq("parse" => [])
  end

  it "answers that commands are off if they were turned off meanwhile" do
    SiteSetting.discord_chat_commands_enabled = false
    described_class.new.execute(args)
    expect(calls.first[:body]["content"]).to eq("Commands are off.")
  end

  it "still answers when the search fails" do
    allow(DiscourseDiscordChat::Commands).to receive(:search).and_raise(StandardError, "boom")
    described_class.new.execute(args)
    expect(calls.first[:body]["content"]).to eq("Search failed. Try again in a minute.")
  end

  it "tries again shortly while Discord hasn't got the thinking message yet" do
    WebMock.stub_request(:patch, %r{/webhooks/555/}).to_return(
      status: 404,
      body: { message: "Unknown Webhook", code: 10_015 }.to_json,
      headers: {
        "Content-Type" => "application/json",
      },
    )
    expect_enqueued_with(job: :discord_chat_answer_command, args: args.merge(attempt: 1)) do
      described_class.new.execute(args)
    end
  end

  it "stops trying after a few attempts" do
    WebMock.stub_request(:patch, %r{/webhooks/555/}).to_return(status: 404, body: "{}")
    expect_not_enqueued_with(job: :discord_chat_answer_command) do
      described_class.new.execute(args.merge(attempt: described_class::RETRIES - 1))
    end
  end
end
