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

  it "leaves emoji out when the forum doesn't draw them" do
    SiteSetting.enable_emoji = false
    reply.update!(raw: "Works great :+1: thanks 🙂 a lot")
    reply.rebake!
    expect(reply.reload.cooked).not_to include("img")

    expect(latest_reply_for(reader)["excerpt"]).to eq("Works great thanks a lot")
  end

  it "leaves emoji out of code spans, and keeps what only looks like one" do
    reply.update!(raw: "Run `:+1: 🙂` at 10:30:45 © :notanemoji:")
    reply.rebake!

    expect(latest_reply_for(reader)["excerpt"]).to eq("Run at 10:30:45 © :notanemoji:")
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

  it "skips deleted replies and small actions for the one before" do
    older = reply
    newer = Fabricate(:post, topic: topic, user: author, raw: "A reply that gets deleted later.")
    newer.trash!
    topic.add_small_action(author, "closed.enabled")

    expect(latest_reply_for(reader)["post_number"]).to eq(older.post_number)
  end

  it "picks each topic's own newest reply across a whole list" do
    other = Fabricate(:topic, user: author)
    Fabricate(:post, topic: other, user: author)
    Fabricate(:post, topic: other, user: replier, raw: "First reply in the other topic.")
    last = Fabricate(:post, topic: other, user: author, raw: "Last reply in the other topic.")

    sign_in(reader)
    get "/latest.json"
    rows = response.parsed_body["topic_list"]["topics"].index_by { |t| t["id"] }
    expect(rows[topic.id]["jt_latest_reply"]["post_number"]).to eq(reply.post_number)
    expect(rows[other.id]["jt_latest_reply"]["post_number"]).to eq(last.post_number)
  end

  # A topic page's Suggested list never shows the reply: working it out there
  # was most of a topic page's time
  it "isn't worked out for a topic page's suggested topics" do
    other = Fabricate(:topic, user: author)
    Fabricate(:post, topic: other, user: author)
    Fabricate(:post, topic: other, user: replier)
    allow(DiscourseJtechTheme::LatestReply).to receive(:latest_posts).and_call_original

    sign_in(reader)
    get "/t/#{topic.id}.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body["suggested_topics"].map { it["id"] }).to include(other.id)
    expect(DiscourseJtechTheme::LatestReply).not_to have_received(:latest_posts)
  end
end
