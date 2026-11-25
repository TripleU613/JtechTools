# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseDiscordChat::Commands do
  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discord_chat_enabled = true
    SiteSetting.discord_chat_commands_enabled = true
  end

  def link_for(topic)
    "(<#{topic.url}>)"
  end

  describe ".search" do
    fab!(:group)
    fab!(:secret_category) { Fabricate(:private_category, group: group) }
    fab!(:public_topic) { Fabricate(:topic, title: "Public zebracorn topic here") }
    fab!(:secret_topic) do
      Fabricate(:topic, title: "Secret zebracorn topic here", category: secret_category)
    end
    fab!(:unlisted_topic) do
      Fabricate(:topic, title: "Unlisted zebracorn topic here", visible: false)
    end
    fab!(:whisper_topic) { Fabricate(:topic, title: "An ordinary topic about cats") }
    fab!(:hidden_topic) { Fabricate(:topic, title: "Another ordinary topic about dogs") }

    let!(:message) do
      SearchIndexer.with_indexing do
        Fabricate(:private_message_post, raw: "zebracorn private message body text")
      end
    end

    before do
      SearchIndexer.enable
      SearchIndexer.with_indexing do
        Fabricate(:post, topic: public_topic, raw: "zebracorn public body text")
        Fabricate(:post, topic: secret_topic, raw: "zebracorn secret body text")
        Fabricate(:post, topic: unlisted_topic, raw: "zebracorn unlisted body text")
        Fabricate(:post, topic: whisper_topic, raw: "a first post about cats")
        Fabricate(
          :post,
          topic: whisper_topic,
          raw: "zebracorn whispered body text",
          post_type: Post.types[:whisper],
        )
        Fabricate(:post, topic: hidden_topic, raw: "a first post about dogs")
        Fabricate(:post, topic: hidden_topic, raw: "zebracorn hidden body text", hidden: true)
      end
    end

    it "finds public topics and nothing a logged-out visitor can't see" do
      result = described_class.search("zebracorn")
      expect(result).to include(link_for(public_topic))
      expect(result).not_to include(link_for(secret_topic))
      expect(result).not_to include(link_for(message.topic))
      expect(result).not_to include(link_for(unlisted_topic))
      expect(result).not_to include(link_for(whisper_topic))
      expect(result).not_to include(link_for(hidden_topic))
    end

    it "finds nothing on a login-required forum" do
      expect(described_class.search("zebracorn")).to include(link_for(public_topic))
      SiteSetting.login_required = true
      expect(described_class.search("zebracorn")).to start_with("Nothing found")
    end

    it "treats filters that need a login as finding nothing" do
      expect(described_class.search("zebracorn in:messages")).to start_with("Nothing found")
    end

    it "says when nothing matches" do
      expect(described_class.search("quuxwobble")).to eq("Nothing found for “quuxwobble”.")
    end
  end

  describe ".guide" do
    fab!(:guides) { Fabricate(:category, name: "Guides", slug: "guides") }
    fab!(:guide_topic) do
      Fabricate(:topic, title: "How to flash zebracorn firmware", category: guides)
    end
    fab!(:other_topic) { Fabricate(:topic, title: "Talking about zebracorn firmware") }

    before do
      SearchIndexer.enable
      SearchIndexer.with_indexing do
        Fabricate(:post, topic: guide_topic, raw: "zebracorn guide body text")
        Fabricate(:post, topic: other_topic, raw: "zebracorn other body text")
      end
    end

    it "finds topics in the Guides category only" do
      result = described_class.guide("zebracorn")
      expect(result).to include(link_for(guide_topic))
      expect(result).not_to include(link_for(other_topic))
    end

    it "finds nothing when Guides is read-restricted" do
      guides.set_permissions(Fabricate(:group) => :full)
      guides.save!
      expect(described_class.guide("zebracorn")).to start_with("No guides found")
    end
  end

  describe ".whois" do
    fab!(:member) { Fabricate(:user, username: "moshe", trust_level: TrustLevel[2]) }

    before do
      UserAssociatedAccount.create!(provider_name: "discord", provider_uid: "42", user: member)
    end

    it "shows username, trust level, join date and profile link" do
      result = described_class.whois("42")
      expect(result).to include("**moshe**")
      expect(result).to include(TrustLevel.name(2))
      expect(result).to include(member.created_at.strftime("%-d %B %Y"))
      expect(result).to include("<#{member.full_url}>")
    end

    it "says not linked for someone who hid their profile" do
      member.user_option.update!(hide_profile: true)
      expect(described_class.whois("42")).to eq(described_class::NOT_LINKED)
    end

    it "says not linked for a suspended account" do
      member.update!(suspended_till: 1.week.from_now, suspended_at: 1.day.ago)
      expect(described_class.whois("42")).to eq(described_class::NOT_LINKED)
    end

    it "says not linked for a staged account" do
      member.update!(staged: true)
      expect(described_class.whois("42")).to eq(described_class::NOT_LINKED)
    end

    it "says not linked on a login-required forum" do
      SiteSetting.login_required = true
      expect(described_class.whois("42")).to eq(described_class::NOT_LINKED)
    end
  end

  describe ".leaderboard" do
    let(:url) { "#{Discourse.base_url}/leaderboard" }

    it "links the leaderboard when Gamification is off" do
      SiteSetting.discourse_gamification_enabled = false
      expect(described_class.leaderboard).to eq("Leaderboard: <#{url}>")
    end

    it "lists the top of the default leaderboard when Gamification is on" do
      SiteSetting.discourse_gamification_enabled = true
      board =
        DiscourseGamification::GamificationLeaderboard.create!(
          name: "Top members",
          created_by_id: Discourse.system_user.id,
        )
      row = Struct.new(:position, :username, :total_score)
      allow(DiscourseGamification::GamificationLeaderboard).to receive(:scores_for).with(
        board.id,
        period: "all_time",
        user_limit: 5,
      ).and_return([row.new(1, "moshe", 120), row.new(2, "yossi_k", 80)])

      expect(described_class.leaderboard).to eq("1. moshe — 120\n2. yossi\\_k — 80\n<#{url}>")
    end

    it "links the leaderboard when the default one is for some groups only" do
      SiteSetting.discourse_gamification_enabled = true
      DiscourseGamification::GamificationLeaderboard.create!(
        name: "Staff only",
        created_by_id: Discourse.system_user.id,
        visible_to_groups_ids: [Group::AUTO_GROUPS[:staff]],
      )
      expect(described_class.leaderboard).to eq("Leaderboard: <#{url}>")
    end
  end
end
