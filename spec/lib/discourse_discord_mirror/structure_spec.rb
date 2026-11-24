# frozen_string_literal: true

require "rails_helper"
require_relative "fake_discord"

RSpec.describe DiscourseDiscordMirror::Structure do
  fab!(:parent) { Fabricate(:category, name: "Phones") }
  fab!(:child) { Fabricate(:category, name: "TCL Phones", parent_category: parent) }
  fab!(:group)
  fab!(:private_category) { Fabricate(:private_category, group: group, name: "Staff") }

  let(:discord) { FakeDiscord.new.install }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discord_mirror_enabled = true
    SiteSetting.discord_mirror_bot_token = "bot-token"
    SiteSetting.discord_mirror_guild_id = "1"
    discord
  end

  it "makes a channel group per top-level category and a read-only forum channel per category" do
    described_class.reconcile

    created = discord.find(:post, %r{\A/guilds/1/channels\z}).map(&:body)
    groups = created.select { |b| b["type"] == described_class::GUILD_CATEGORY }
    forums = created.select { |b| b["type"] == described_class::GUILD_FORUM }
    expect(groups.map { |b| b["name"] }).to include("Phones")
    expect(forums.map { |b| b["name"] }).to include("Phones", "TCL Phones")
    expect(forums.map { |b| b["permission_overwrites"] }).to all(
      eq([{ "id" => "1", "type" => 0, "deny" => described_class::READ_ONLY_DENY.to_s }]),
    )

    rows = DiscourseDiscordMirror::MirrorChannel.where(category_id: [parent.id, child.id])
    expect(rows.count).to eq(2)
    expect(rows.map(&:discord_group_id).uniq.size).to eq(1)
  end

  it "never makes a channel for a category guests can't read" do
    described_class.reconcile
    names = discord.find(:post, %r{\A/guilds/1/channels\z}).map { |c| c.body["name"] }
    expect(names).not_to include("Staff")
    expect(
      DiscourseDiscordMirror::MirrorChannel.find_by(category_id: private_category.id),
    ).to be_nil
  end

  it "removes the channel, with its threads, once a category turns private" do
    described_class.reconcile
    row = DiscourseDiscordMirror::MirrorChannel.find_by(category_id: child.id)
    DiscourseDiscordMirror::MirrorThread.create!(
      topic_id: 99,
      category_id: child.id,
      discord_thread_id: "5",
      title_sent: "x",
    )
    discord.reset

    child.set_permissions(group => :full)
    child.save!
    described_class.reconcile

    expect(discord.find(:delete, %r{\A/channels/#{row.discord_channel_id}\z})).to be_present
    expect(DiscourseDiscordMirror::MirrorChannel.find_by(category_id: child.id)).to be_nil
    expect(DiscourseDiscordMirror::MirrorThread.find_by(topic_id: 99)).to be_nil
  end
end
