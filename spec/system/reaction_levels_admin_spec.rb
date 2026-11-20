# frozen_string_literal: true

require "rails_helper"

# The Reaction levels tab's grid: a click on a column sets the reaction's
# lowest level and saves the per-level lists
RSpec.describe "Reaction levels admin grid", if: defined?(DiscourseReactions) do
  fab!(:admin)

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discourse_reactions_enabled = true
    SiteSetting.discourse_reactions_reaction_for_like = "heart"
    SiteSetting.discourse_reactions_enabled_reactions = "laughing|trophy"
    SiteSetting.jtech_reaction_levels_enabled = true
    SiteSetting.jtech_reaction_levels_tl2 = "trophy"
  end

  def track(emoji)
    find(".jtech-rl__track[aria-label='#{emoji}']")
  end

  it "shows each reaction's level and saves a new one from a click" do
    sign_in(admin)
    visit "/admin/plugins/jtech-tools/reaction-levels"

    expect(track("trophy")["aria-valuenow"]).to eq("2")
    expect(track("laughing")["aria-valuenow"]).to eq("0")
    expect(track("heart")["aria-disabled"]).to eq("true")

    track("trophy").all(".jtech-rl__cell")[4].click
    expect(page).to have_css(".jtech-rl__status", text: "Saved")
    expect(track("trophy")["aria-valuenow"]).to eq("4")
    expect(SiteSetting.jtech_reaction_levels_tl4).to eq("trophy")
    expect(SiteSetting.jtech_reaction_levels_tl2).to eq("")

    track("laughing").all(".jtech-rl__cell")[5].click
    expect(page).to have_css(".jtech-rl__status", text: "Saved")
    expect(SiteSetting.jtech_reaction_levels_staff).to eq("laughing")
  end
end
