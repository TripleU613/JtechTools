# frozen_string_literal: true

require "rails_helper"

# jtech_topic_list_latest_reply: each topic in a list carries the newest
# reply its reader can read, for the JTech theme's cards.
RSpec.describe "Topic list latest reply" do
  fab!(:reader, :user)
  fab!(:moderator)
  fab!(:author, :user)
  fab!(:replier) { Fabricate(:user, username: "replier") }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:op) { Fabricate(:post, topic: topic, user: author, raw: "The opening post of the topic.") }
  fab!(:reply) do
    Fabricate(:post, topic: topic, user: replier, raw: "The newest public reply here.")
  end

  before { SiteSetting.jtech_topic_list_latest_reply = true }

  def latest_reply_for(user)
    user ? sign_in(user) : nil
    get "/latest.json"
    expect(response.status).to eq(200)
    row = response.parsed_body["topic_list"]["topics"].find { |t| t["id"] == topic.id }
    row["jt_latest_reply"]
  end

  it "gives the newest reply, with who wrote it" do
    latest = latest_reply_for(reader)

    expect(latest["post_number"]).to eq(reply.post_number)
    expect(latest["username"]).to eq("replier")
    expect(latest["excerpt"]).to include("newest public reply")
  end

  it "leaves emoji out of the excerpt" do
    reply.update!(raw: "Works great :+1: thanks 🙂 a lot")
    reply.rebake!
    expect(reply.reload.cooked).to include("emoji")

    expect(latest_reply_for(reader)["excerpt"]).to eq("Works great thanks a lot")
  end

  it "gives it to visitors too" do
    expect(latest_reply_for(nil)["post_number"]).to eq(reply.post_number)
  end

  it "skips a whisper the reader isn't part of" do
    whisper = Fabricate(:post, topic: topic, user: moderator, raw: "A whisper among staff only.")
    whisper.custom_fields[DiscourseModCategories::POST_WHISPER_TARGETS_FIELD] = []
    whisper.save_custom_fields(true)

    expect(latest_reply_for(reader)["post_number"]).to eq(reply.post_number)
    expect(latest_reply_for(moderator)["post_number"]).to eq(whisper.post_number)
  end

  it "skips hidden posts and people the reader ignores" do
    hidden = Fabricate(:post, topic: topic, user: author, raw: "A post hidden by flags.")
    hidden.update_columns(hidden: true)
    expect(latest_reply_for(reader)["post_number"]).to eq(reply.post_number)

    Fabricate(:ignored_user, user: reader, ignored_user: replier)
    expect(latest_reply_for(reader)).to be_nil
  end

  it "has nothing for a topic without replies" do
    reply.trash!
    topic.update_columns(highest_post_number: 1)
    expect(latest_reply_for(reader)).to be_nil
  end

  it "isn't sent with the setting off" do
    SiteSetting.jtech_topic_list_latest_reply = false
    expect(latest_reply_for(reader)).to be_nil
  end
end
