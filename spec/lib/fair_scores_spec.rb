# frozen_string_literal: true

require "rails_helper"

# jtech_fair_scores: the capped queries discourse-gamification's reply and like
# scorers run instead of their own. Built here without the plugin, run as the
# plugin runs them.
RSpec.describe DiscourseFairScores do
  fab!(:writer, :user)
  fab!(:fan, :user)
  fab!(:other_fan, :user)
  fab!(:topic) { Fabricate(:topic, user: Fabricate(:user)) }
  fab!(:op) { Fabricate(:post, topic: topic, user: topic.user) }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_fair_scores = true
    SiteSetting.jtech_fair_scores_replies_per_day = 2
    SiteSetting.jtech_fair_scores_likes_per_person_per_day = 2
    SiteSetting.jtech_fair_scores_likes_given_per_day = 3
  end

  def points(sql)
    DB
      .query(sql, since: 1.day.ago)
      .group_by(&:user_id)
      .transform_values { |rows| rows.sum(&:points) }
  end

  def replies(user, count)
    Array.new(count) { Fabricate(:post, topic: topic, user: user) }
  end

  def like(user, post)
    PostActionCreator.like(user, post)
  end

  it "counts only the first replies of the day" do
    replies(writer, 5)

    expect(points(described_class.replies_sql(points: 5))[writer.id]).to eq(2 * 5)
  end

  it "counts a few likes a day from any one person" do
    posts = replies(writer, 4)
    posts.each { like(fan, it) }
    like(other_fan, posts.first)

    expect(points(described_class.likes_received_sql(points: 3))[writer.id]).to eq((2 + 1) * 3)
  end

  it "counts only the first likes a person gives each day, and not ones taken back" do
    posts = replies(writer, 5)
    posts.each { like(fan, it) }
    PostActionDestroyer.destroy(fan, posts.last, :like)

    expect(points(described_class.likes_given_sql(points: 1))[fan.id]).to eq(3)
  end

  it "leaves private messages out" do
    pm = Fabricate(:private_message_topic, user: writer)
    Fabricate(:post, topic: pm, user: writer, post_number: 2)

    expect(points(described_class.replies_sql(points: 5))[writer.id]).to be_nil
  end

  describe "in place of the plugin's queries" do
    let(:scorer) do
      Class.new do
        def self.name = "DiscourseGamification::PostCreated"
        def self.query(leaderboard: nil) = "stock"
        def self.score_multiplier(leaderboard: nil) = 5
        def self.category_filter(leaderboard: nil) = ""
        singleton_class.prepend(DiscourseFairScores::ScorerQuery)
      end
    end

    it "runs the capped query while on" do
      expect(scorer.query).to eq(described_class.replies_sql(points: 5))
    end

    it "leaves the plugin's own query with the setting off" do
      SiteSetting.jtech_fair_scores = false
      expect(scorer.query).to eq("stock")
    end

    it "leaves the plugin's own query with Jtech off" do
      SiteSetting.jtech_enabled = false
      expect(scorer.query).to eq("stock")
    end
  end
end
