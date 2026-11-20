# frozen_string_literal: true

require "rails_helper"

# The reactions picker offers only what the member's trust level unlocked
RSpec.describe "Reaction levels in the picker", if: defined?(DiscourseReactions) do
  fab!(:author, :user)
  fab!(:newbie) { Fabricate(:user, trust_level: TrustLevel[1], refresh_auto_groups: true) }
  fab!(:regular) { Fabricate(:user, trust_level: TrustLevel[3], refresh_auto_groups: true) }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:post) { Fabricate(:post, topic: topic, user: author) }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discourse_reactions_enabled = true
    SiteSetting.discourse_reactions_reaction_for_like = "heart"
    SiteSetting.discourse_reactions_enabled_reactions = "laughing|trophy"
    SiteSetting.jtech_reaction_levels_enabled = true
    SiteSetting.jtech_reaction_levels_tl3 = "trophy"
  end

  def open_picker
    visit topic.relative_url
    find("#discourse-reactions-actions-#{post.id}-right").hover
    expect(page).to have_css(".discourse-reactions-picker.is-expanded")
  end

  it "hides a reaction the member hasn't unlocked" do
    sign_in(newbie)
    open_picker
    expect(page).to have_css(".pickable-reaction.laughing")
    expect(page).to have_no_css(".pickable-reaction.trophy")
  end

  it "shows it once their trust level unlocks it" do
    sign_in(regular)
    open_picker
    expect(page).to have_css(".pickable-reaction.laughing")
    expect(page).to have_css(".pickable-reaction.trophy")
  end
end
