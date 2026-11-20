# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reaction levels", if: defined?(DiscourseReactions) do
  fab!(:newbie) { Fabricate(:user, trust_level: TrustLevel[1], refresh_auto_groups: true) }
  fab!(:regular) { Fabricate(:user, trust_level: TrustLevel[3], refresh_auto_groups: true) }
  fab!(:post)

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discourse_reactions_enabled = true
    SiteSetting.discourse_reactions_reaction_for_like = "heart"
    SiteSetting.discourse_reactions_enabled_reactions = "+1|laughing|trophy"
    SiteSetting.jtech_reaction_levels_enabled = true
    SiteSetting.jtech_reaction_levels_tl3 = "trophy"
  end

  def react(reaction)
    put "/discourse-reactions/posts/#{post.id}/custom-reactions/#{reaction}/toggle.json"
  end

  it "refuses a reaction the member's trust level hasn't unlocked, and allows the rest" do
    sign_in(newbie)

    react("trophy")
    expect(response.status).to eq(403)
    expect(response.parsed_body["errors"].first).to include("trust level 3")

    react("laughing")
    expect(response.status).to eq(200)
  end

  it "lets a member who has unlocked it react with it" do
    sign_in(regular)
    react("trophy")
    expect(response.status).to eq(200)
  end

  it "always lets a member take back a reaction they already gave" do
    sign_in(regular)
    react("trophy")
    expect(response.status).to eq(200)

    SiteSetting.jtech_reaction_levels_tl4 = "trophy"
    SiteSetting.jtech_reaction_levels_tl3 = ""
    react("trophy")
    expect(response.status).to eq(200)
    expect(DiscourseReactions::ReactionUser.where(user: regular).count).to eq(0)
  end

  it "tells the picker what each member may use" do
    sign_in(newbie)
    get "/session/current.json"
    expect(response.parsed_body["current_user"]["jt_reactions"]).to eq(%w[heart +1 laughing])

    SiteSetting.jtech_reaction_levels_enabled = false
    get "/session/current.json"
    expect(response.parsed_body["current_user"]).not_to have_key("jt_reactions")
  end
end
