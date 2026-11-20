# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseReactionLevels, if: defined?(DiscourseReactions) do
  fab!(:newbie) { Fabricate(:user, trust_level: TrustLevel[0]) }
  fab!(:member) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:regular) { Fabricate(:user, trust_level: TrustLevel[3]) }
  fab!(:moderator)

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.discourse_reactions_enabled = true
    SiteSetting.discourse_reactions_reaction_for_like = "heart"
    SiteSetting.discourse_reactions_enabled_reactions = "+1|laughing|fire|trophy|clap"
    SiteSetting.jtech_reaction_levels_enabled = true
    SiteSetting.jtech_reaction_levels_tl2 = "fire"
    SiteSetting.jtech_reaction_levels_tl3 = "trophy|fire"
  end

  it "opens unlisted reactions to everyone and unlocks the rest at their lowest level" do
    expect(described_class.allowed_for(newbie)).to eq(%w[heart +1 laughing clap])
    expect(described_class.allowed_for(member)).to eq(%w[heart +1 laughing fire clap])
    expect(described_class.allowed_for(regular)).to eq(%w[heart +1 laughing fire trophy clap])
  end

  it "keeps a staff-only reaction from every trust level" do
    SiteSetting.jtech_reaction_levels_staff = "clap"
    expect(described_class.allowed_for(regular)).not_to include("clap")
    expect(described_class.allowed_for(moderator)).to be_nil
  end

  it "holds nothing back for staff, or with the switch or Jtech off" do
    expect(described_class.allowed_for(moderator)).to be_nil

    SiteSetting.jtech_reaction_levels_enabled = false
    expect(described_class.allowed_for(newbie)).to be_nil

    SiteSetting.jtech_reaction_levels_enabled = true
    SiteSetting.jtech_enabled = false
    expect(described_class.allowed_for(newbie)).to be_nil
  end

  it "lays out each level for the admin tab, and notes listed reactions that aren't enabled" do
    SiteSetting.jtech_reaction_levels_tl4 = "rocket"
    table = described_class.table

    expect(table[:rows].find { it[:level] == 2 }[:unlocks]).to eq(["fire"])
    expect(table[:rows].find { it[:level] == 3 }[:unlocks]).to eq(["trophy"])
    expect(table[:everyone]).to eq(%w[heart +1 laughing clap])
    expect(table[:not_enabled]).to eq(["rocket"])
  end
end
