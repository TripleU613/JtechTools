# frozen_string_literal: true

require "rails_helper"
require_relative "fake_discord"

RSpec.describe DiscourseDiscordMirror::TopicSync do
  fab!(:category)
  fab!(:author) { Fabricate(:user, username: "moshe") }
  fab!(:replier) { Fabricate(:user, username: "yossi") }
  fab!(:group)
  fab!(:private_category) { Fabricate(:private_category, group: group) }
  fab!(:topic) do
    Fabricate(:topic, category: category, user: author, title: "TCL Flip 2 screen in sunlight")
  end
  fab!(:first_post) do
    Fabricate(
      :post,
      topic: topic,
      user: author,
      raw: "How bright is it outside?",
      cooked: "<p>How bright is it outside?</p>",
    )
  end
  fab!(:reply) do
    Fabricate(
      :post,
      topic: topic,
      user: replier,
      raw: "Very readable @everyone",
      cooked: "<p>Very readable @everyone</p>",
    )
  end

  let(:discord) { FakeDiscord.new.install }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discord_mirror_enabled = true
    SiteSetting.discord_mirror_bot_token = "bot-token"
    SiteSetting.discord_mirror_guild_id = "1"
    discord
  end

  def sync(id = topic.id)
    result = nil
    3.times do
      result = described_class.new(id).run
      break if result == :done
    end
    result
  end

  def thread_row
    DiscourseDiscordMirror::MirrorThread.find_by(topic_id: topic.id)
  end

  def webhook_posts
    discord.find(:post, %r{\A/webhooks/})
  end

  it "opens a thread with the first post and adds the replies to it, in order" do
    expect(sync).to eq(:done)

    first, second = webhook_posts
    expect(first.body["thread_name"]).to eq("TCL Flip 2 screen in sunlight")
    expect(first.body["username"]).to eq("moshe")
    expect(first.body["content"]).to include("How bright is it outside?")
    expect(first.body["content"]).to include(first_post.full_url)
    expect(second.query["thread_id"]).to eq(thread_row.discord_thread_id)
    expect(second.body["username"]).to eq("yossi")
    expect(DiscourseDiscordMirror::MirrorMessage.where(topic_id: topic.id).count).to eq(2)
  end

  it "never lets a post ping anyone on Discord" do
    sync
    expect(webhook_posts.map { |c| c.body["allowed_mentions"] }).to all(eq({ "parse" => [] }))
  end

  it "sends nothing again when nothing changed" do
    sync
    discord.reset
    sync
    expect(webhook_posts).to be_empty
    expect(discord.find(:patch, %r{\A/webhooks/})).to be_empty
  end

  it "edits the Discord message when the post is edited" do
    sync
    discord.reset
    reply.update!(cooked: "<p>Actually it washes out</p>")
    sync
    edit = discord.find(:patch, %r{\A/webhooks/}).first
    expect(edit.body["content"]).to include("Actually it washes out")
  end

  describe "keeping private things private" do
    it "doesn't send a whisper" do
      reply.custom_fields[DiscourseModCategories::Whisper.targets_field] = [author.id]
      reply.save_custom_fields
      sync
      expect(webhook_posts.size).to eq(1)
    end

    it "doesn't send a hidden post, a staff note or a whisper by post type" do
      reply.update!(hidden: true)
      Fabricate(:post, topic: topic, post_type: Post.types[:whisper], raw: "staff only words")
      Fabricate(:post, topic: topic, post_type: Post.types[:small_action], raw: "closed")
      sync
      expect(webhook_posts.size).to eq(1)
    end

    it "takes a reply down once it's deleted, hidden or whispered" do
      sync
      discord.reset
      reply.update!(hidden: true)
      sync
      expect(discord.find(:delete, %r{\A/webhooks/.+/messages/})).to be_present
      expect(DiscourseDiscordMirror::MirrorMessage.where(post_id: reply.id)).to be_empty
    end

    it "takes the whole thread down when the topic is unlisted" do
      sync
      thread_id = thread_row.discord_thread_id
      discord.reset
      topic.update!(visible: false)
      sync
      expect(discord.find(:delete, %r{\A/channels/#{thread_id}\z})).to be_present
      expect(thread_row).to be_nil
      expect(DiscourseDiscordMirror::MirrorMessage.where(topic_id: topic.id)).to be_empty
    end

    it "takes the whole thread down when the topic moves to a private category" do
      sync
      discord.reset
      topic.update!(category: private_category)
      sync
      expect(discord.find(:delete, %r{\A/channels/\d+\z})).to be_present
      expect(thread_row).to be_nil
      expect(webhook_posts).to be_empty
    end

    it "takes the whole thread down when the topic is deleted" do
      sync
      discord.reset
      topic.trash!
      sync
      expect(thread_row).to be_nil
    end

    it "sends nothing from a private category, an excluded one or a private message" do
      private_topic = Fabricate(:topic, category: private_category)
      Fabricate(:post, topic: private_topic)
      pm = Fabricate(:private_message_topic)
      Fabricate(:post, topic: pm)
      SiteSetting.discord_mirror_excluded_categories = category.id.to_s

      [private_topic, pm, topic].each { |t| sync(t.id) }
      expect(discord.calls).to be_empty
    end
  end

  it "resends an anonymized member's posts under the new name" do
    sync
    discord.reset
    DiscourseDiscordMirror::MirrorMessage.where(user_id: replier.id).update_all(
      content_digest: described_class::RESEND,
    )
    replier.update!(username: "anon123")
    sync
    expect(discord.find(:delete, %r{\A/webhooks/.+/messages/}).size).to eq(1)
    expect(webhook_posts.map { |c| c.body["username"] }).to eq(["anon123"])
  end

  it "locks the thread when the topic is closed" do
    sync
    discord.reset
    topic.update!(closed: true)
    sync
    lock = discord.find(:patch, %r{\A/channels/#{thread_row.discord_thread_id}\z}).first
    expect(lock.body).to include("locked" => true)
  end

  it "stops with :more on a long topic and finishes on the next run" do
    stub_const("#{described_class}::CALLS_PER_RUN", 1)
    expect(described_class.new(topic.id).run).to eq(:more)
    expect(described_class.new(topic.id).run).to eq(:done)
    expect(webhook_posts.size).to eq(2)
  end

  it "passes Discord's rate limit up so the job can wait" do
    WebMock.stub_request(:post, %r{/webhooks/}).to_return(
      status: 429,
      body: { retry_after: 3.2 }.to_json,
    )
    expect { described_class.new(topic.id).run }.to raise_error(
      DiscourseDiscordMirror::Api::RateLimited,
    ) { |e| expect(e.retry_after).to eq(4) }
  end
end
