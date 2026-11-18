# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseJtechAds do
  fab!(:member) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:group)

  def ads(*entries)
    SiteSetting.jtech_ads_list =
      entries
        .map do
          { "name" => "a", "enabled" => true, "headline" => "Hi", "audience" => "everyone" }.merge(
            it,
          )
        end
        .to_json
  end

  def headlines(user)
    described_class.visible_to(Guardian.new(user)).map(&:headline)
  end

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_ads_enabled = true
  end

  describe ".clean" do
    it "keeps text and inline tags, and drops images, video, scripts, styles and handlers" do
      html =
        %(<b>Big</b> <img src="x.png"><video src="v.mp4"></video><script>alert(1)</script>) +
          %(<i style="color:red" class="x" onclick="evil()">sale</i><iframe src="//x"></iframe>)

      expect(described_class.clean(html)).to eq("<b>Big</b> <i>sale</i>")
    end

    it "keeps safe links, opens other sites in a new tab, and disarms script links" do
      expect(described_class.clean(%(<a href="/about">us</a>))).to eq(
        %(<a href="/about" rel="nofollow noopener">us</a>),
      )
      expect(described_class.clean(%(<a href="https://example.com">them</a>))).to eq(
        %(<a href="https://example.com" rel="nofollow noopener" target="_blank">them</a>),
      )
      expect(described_class.clean(%(<a href="javascript:alert(1)">x</a>))).to eq("<a>x</a>")
    end
  end

  describe ".visible_to" do
    it "follows each ad's audience" do
      ads(
        { "name" => "all", "headline" => "All" },
        { "name" => "out", "headline" => "Visitors", "audience" => "visitors" },
        { "name" => "in", "headline" => "Members", "audience" => "members" },
        { "name" => "grp", "headline" => "Group", "audience" => "groups", "groups" => [group.id] },
      )

      expect(headlines(nil)).to contain_exactly("All", "Visitors")
      expect(headlines(member)).to contain_exactly("All", "Members")

      group.add(member)
      expect(headlines(member)).to contain_exactly("All", "Members", "Group")
    end

    it "leaves out paused and ended ads, and keeps ones that start later for the browser to wait on" do
      ads(
        { "name" => "paused", "headline" => "Paused", "enabled" => false },
        { "name" => "over", "headline" => "Over", "ends_at" => 1.day.ago.iso8601 },
        { "name" => "soon", "headline" => "Soon", "starts_at" => 1.day.from_now.iso8601 },
      )

      expect(headlines(member)).to eq(["Soon"])
    end

    it "gives each ad a key from its name" do
      ads({ "name" => "spring" })
      expect(described_class.visible_to(Guardian.new).first.key).to eq(
        described_class.key_for("spring"),
      )
      expect(described_class.key_for("spring")).to match(described_class::KEY_FORMAT)
    end
  end
end
