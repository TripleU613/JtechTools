# frozen_string_literal: true

require "rails_helper"

# The ad space as a plain card, in a theme that doesn't carry it itself
# (here: core's default theme)
RSpec.describe "Ads in the welcome area" do
  fab!(:member) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:admin)
  fab!(:topic)
  fab!(:post) { Fabricate(:post, topic: topic) }

  let(:card) do
    %(<div class="jl-split"><div class="jl-stack"><h2 class="jl-title-xl">Spring sale</h2>) +
      %(<p class="jl-lead">Ends <b>Friday</b></p><div class="jl-row"><a class="jl-button" href="/about">Look</a></div></div>) +
      %(<div class="jl-panel jl-center"><p class="jl-stat">40%</p></div></div>)
  end

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_ads_enabled = true
    SiteSetting.jtech_ads_list = [
      { name: "spring", enabled: true, headline: "Spring sale", card:, audience: "everyone" },
    ].to_json
  end

  it "fills the space with the ad's card, labelled, and not inside a topic" do
    visit "/latest"
    expect(page).to have_css(".jt-lines .jt-lines__label", text: "Ad")
    expect(page).to have_css(".jt-lines .jl-title-xl", text: "Spring sale")
    expect(page).to have_css(".jt-lines .jl-lead b", text: "Friday")
    expect(page).to have_css(".jt-lines a.jl-button[href='/about']")
    expect(page).to have_no_css(".jt-lines__thumb")

    visit topic.relative_url
    expect(page).to have_css("#post_1")
    expect(page).to have_no_css(".jt-lines")
  end

  it "keeps the space's size whatever the ad holds" do
    visit "/latest"
    expect(page).to have_css(".jt-lines .jl-card")
    short =
      page.evaluate_script("document.querySelector('.jt-lines').getBoundingClientRect().height")

    SiteSetting.jtech_ads_list = [
      {
        name: "long",
        enabled: true,
        headline: "Long",
        card: "<div class=\"jl-stack\">#{%(<h2 class="jl-title-xl">#{"Big " * 60}</h2><p class="jl-lead">#{"word " * 300}</p>) * 2}</div>",
      },
    ].to_json
    visit "/latest"
    expect(page).to have_css(".jt-lines .jl-card")
    long =
      page.evaluate_script("document.querySelector('.jt-lines').getBoundingClientRect().height")
    expect(long).to eq(short)
  end

  it "lets a member give it a thumb" do
    sign_in(member)
    visit "/latest"
    find(".jt-lines__thumb[title='I like this']").click
    expect(page).to have_css(".jt-lines__thumb[aria-pressed='true']")
    expect(DiscourseJtechAds::Vote.find_by(user: member).value).to eq(1)
  end

  it "shows an admin a preview of a draft, and nobody else" do
    token =
      DiscourseJtechAds::Manager.preview!(
        entry: {
          "name" => "draft",
          "headline" => "Draft",
          "card" => %(<h2 class="jl-title">Draft card</h2>),
        },
      )[
        :token
      ]

    sign_in(admin)
    visit "/latest?jl_preview=#{token}"
    expect(page).to have_css(".jt-lines .jl-title", text: "Draft card")
    expect(page).to have_css(".jt-lines__label", text: "Preview")

    sign_in(member)
    visit "/latest?jl_preview=#{token}"
    expect(page).to have_css(".jt-lines .jl-title-xl", text: "Spring sale")
    expect(page).to have_no_text("Draft card")
  end

  # A blocker's element rule, applied as soon as the page is up: the space
  # checks itself after a second and a half, and moves the ad
  it "moves the ad to the fallback when the space is hidden" do
    visit "/latest"
    page.execute_script(<<~JS)
      const style = document.createElement("style");
      style.textContent = ".jt-lines { display: none !important }";
      document.head.append(style);
    JS
    expect(page).to have_css("[data-jt-l]", wait: 5)
  end

  it "keeps out of the class names blockers look for" do
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
