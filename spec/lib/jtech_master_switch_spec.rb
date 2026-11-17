# frozen_string_literal: true

require "rails_helper"

# jtech_enabled is the bundle's master switch. Discourse's own plugin gate
# stops event hooks, serializers and assets when it is off, but not the
# modules' core-class patches or scheduled jobs — those read the module
# helpers below, which must honor the master too.
RSpec.describe "Jtech master switch" do
  {
    "DiscourseMiniMod" => :mini_mod_enabled,
    "DiscourseModCategories" => :mod_categories_enabled,
    "DiscourseDisteleplus" => :disteleplus_enabled,
    "DiscourseDumbcourse" => :dumbcourse_enabled,
    "DiscourseReqpm" => :reqpm_enabled,
    "DiscourseListingFormat" => :listing_format_enabled,
    "DiscourseModElections" => :mod_elections_enabled,
  }.each do |mod_name, setting|
    describe "#{mod_name}.enabled?" do
      let(:mod) { mod_name.constantize }

      it "is on only while both the module switch and the master are on" do
        SiteSetting.jtech_enabled = true
        SiteSetting.public_send("#{setting}=", true)
        expect(mod.enabled?).to eq(true)

        SiteSetting.jtech_enabled = false
        expect(mod.enabled?).to eq(false)

        SiteSetting.jtech_enabled = true
        SiteSetting.public_send("#{setting}=", false)
        expect(mod.enabled?).to eq(false)
      end
    end
  end

  describe "Mini-mod's Guardian patch" do
    fab!(:tl4) { Fabricate(:user, trust_level: TrustLevel[4]) }
    fab!(:topic) { Fabricate(:topic, closed: true) }

    before do
      SiteSetting.mini_mod_enabled = true
      SiteSetting.tl4_can_post_in_closed_topics = false
    end

    it "applies its TL4 closed-topic restriction while the master is on" do
      SiteSetting.jtech_enabled = true
      expect(Guardian.new(tl4).can_create_post_on_topic?(topic)).to eq(false)
    end

    it "falls back to core behavior once the master is off" do
      # Core's answer, with the patch out of the way via its own switch.
      SiteSetting.jtech_enabled = true
      SiteSetting.mini_mod_enabled = false
      core = Guardian.new(tl4).can_create_post_on_topic?(topic)

      # The reported bug: module switch still on, master off.
      SiteSetting.jtech_enabled = false
      SiteSetting.mini_mod_enabled = true
      expect(Guardian.new(tl4).can_create_post_on_topic?(topic)).to eq(core)
    end
  end

  describe "Disteleplus access" do
    fab!(:admin)

    it "closes the conversation to everyone once the master is off" do
      SiteSetting.disteleplus_enabled = true
      SiteSetting.jtech_enabled = true
      expect(DiscourseDisteleplus::Access.allowed?(admin)).to eq(true)

      SiteSetting.jtech_enabled = false
      expect(DiscourseDisteleplus::Access.allowed?(admin)).to eq(false)
    end
  end
end
