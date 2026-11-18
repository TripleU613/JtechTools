# frozen_string_literal: true

require "rails_helper"

# The welcome area's ad as a plain card, in a theme that doesn't draw it
# itself (here: core's default theme)
RSpec.describe "Ads in the welcome area" do
  fab!(:member) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic)
  fab!(:post) { Fabricate(:post, topic: topic) }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_ads_enabled = true
    SiteSetting.jtech_ads_list = [
      {
        name: "spring",
        enabled: true,
        headline: "Spring sale",
        text: "Ends <b>Friday</b>",
        audience: "everyone",
      },
    ].to_json
  end

  it "shows the ad on the home page, with its label, and not inside a topic" do
    visit "/latest"
    expect(page).to have_css(".jt-lines .jt-lines__label", text: "Ad")
    expect(page).to have_css(".jt-lines .jt-lines__head", text: "Spring sale")
    expect(page).to have_css(".jt-lines .jt-lines__text b", text: "Friday")
    expect(page).to have_no_css(".jt-lines__thumb")

    visit topic.relative_url
    expect(page).to have_css("#post_1")
    expect(page).to have_no_css(".jt-lines")
  end

  it "lets a member give it a thumb" do
    sign_in(member)
    visit "/latest"
    find(".jt-lines__thumb[title='I like this']").click
    expect(page).to have_css(".jt-lines__thumb[aria-pressed='true']")
    expect(DiscourseJtechAds::Vote.find_by(user: member).value).to eq(1)
  end

  it "keeps out of the class names and requests blockers look for" do
    visit "/latest"
    expect(page).to have_css(".jt-lines")
    named = page.evaluate_script(<<~JS)
        [...document.querySelectorAll(".jt-lines, .jt-lines *")]
          .flatMap((el) => [...el.classList, el.id])
          .filter((name) => /(^|[^a-z])(ads?|advert|sponsor|banner|promo)([^a-z]|$)/i.test(name))
      JS
    expect(named).to eq([])
  end
end
