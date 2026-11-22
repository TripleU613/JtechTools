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
        card:
          "<div class=\"jl-stack\">#{%(<h2 class="jl-title-xl">#{"Big " * 60}</h2><p class="jl-lead">#{"word " * 300}</p>) * 2}</div>",
      },
    ].to_json
    visit "/latest"
    expect(page).to have_css(".jt-lines .jl-card")
    long =
      page.evaluate_script("document.querySelector('.jt-lines').getBoundingClientRect().height")
    expect(long).to eq(short)
  end

  it "confirms when a member adds, changes, or removes feedback" do
    sign_in(member)
    visit "/latest"

    within(".jt-lines") do
      click_button "I like this"
      expect(page).to have_css("[role='status']", text: "Liked", exact_text: true, visible: true)
      expect(page).to have_css("button[aria-label='I like this'][aria-pressed='true']")

      click_button "Not for me"
      expect(page).to have_css("[role='status']", text: "Disliked", exact_text: true, visible: true)
      expect(page).to have_css("button[aria-label='Not for me'][aria-pressed='true']")
      expect(page).to have_css("button[aria-label='I like this'][aria-pressed='false']")
    end

    page.refresh

    within(".jt-lines") do
      expect(page).to have_css("[role='status']", text: "Disliked", exact_text: true, visible: true)
      click_button "Not for me"
      expect(page).to have_css(
        "[role='status']",
        text: "Vote removed",
        exact_text: true,
        visible: true,
      )
      expect(page).to have_no_css(".jt-lines__thumb[aria-pressed='true']")
    end

    expect(DiscourseJtechAds::Vote.find_by(user: member)).to be_nil
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

  # The fallback's root is closed; in these specs every root is opened, so
  # they can look inside
  def open_shadow_roots
    page.driver.with_playwright_page { |pw| pw.add_init_script(script: <<~JS) }
        const attachShadow = Element.prototype.attachShadow;
        Element.prototype.attachShadow = function (options) {
          return attachShadow.call(this, { ...options, mode: "open" });
        };
      JS
  end

  def hide_space
    page.execute_script(<<~JS)
      const style = document.createElement("style");
      style.textContent = ".jt-lines { display: none !important }";
      document.head.append(style);
    JS
  end

  let(:host) do
    "[...document.querySelectorAll('#main-outlet div')].find((el) => el.shadowRoot?.querySelector('.jt-lines'))"
  end
  let(:fallback) { "#{host}?.shadowRoot" }

  # A blocker's element rule, applied as soon as the page is up: the space
  # checks itself after a second and a half, and moves the ad
  it "moves the ad to the fallback when the space is hidden" do
    open_shadow_roots
    visit "/latest"
    hide_space
    try_until_success(timeout: 5) do
      expect(page.evaluate_script("#{fallback}?.querySelector('.jl-title-xl')?.textContent")).to eq(
        "Spring sale",
      )
    end
  end

  # Nothing outside the root a page rule could name, and a script that
  # hides it is undone
  it "gives the fallback nothing to be named by, and undoes hiding" do
    open_shadow_roots
    visit "/latest"
    hide_space
    try_until_success(timeout: 5) { expect(page.evaluate_script("!!#{fallback}")).to eq(true) }

    outside = page.evaluate_script(<<~JS)
      (() => { const host = #{host}; return [host, host.parentElement].map((el) => [...el.attributes].map((a) => a.name + "=" + a.value)); })()
    JS
    outside.each { |attributes| expect(attributes).to match([/\Aclass=c[a-z0-9]+\z/]) }

    page.execute_script("#{host}.style.setProperty('display', 'none', 'important')")
    page.execute_script("#{host}.parentElement.setAttribute('data-jtab-shadow', '')")
    try_until_success do
      expect(page.evaluate_script("getComputedStyle(#{host}).display")).to eq("block")
      expect(page.evaluate_script("#{host}.parentElement.hasAttribute('data-jtab-shadow')")).to eq(
        false,
      )
    end
  end

  it "keeps the vote and confirms updates on the fallback card" do
    DiscourseJtechAds::Vote.create!(
      user: member,
      ad_key: DiscourseJtechAds.key_for("spring"),
      value: 1,
    )
    open_shadow_roots
    sign_in(member)
    visit "/latest"
    hide_space
    try_until_success(timeout: 5) { expect(page.evaluate_script("!!#{fallback}")).to eq(true) }

    feedback = "#{fallback}.querySelector('[role=status]')"
    expect(page.evaluate_script("#{feedback}.textContent")).to eq("Liked")
    page.execute_script("#{fallback}.querySelector(\"[aria-label='Not for me']\").click()")
    try_until_success { expect(page.evaluate_script("#{feedback}.textContent")).to eq("Disliked") }
    expect(DiscourseJtechAds::Vote.find_by(user: member).value).to eq(-1)
  end

  # An app trying everything: it can't touch the page, the space's size or
  # the label, and nothing loads from anywhere else
  it "seals an app off from the page and the network" do
    SiteSetting.jtech_ads_list = [
      {
        name: "hostile",
        enabled: true,
        headline: "Hostile",
        card:
          %(<div class="big"><h2 class="t">Inside</h2><div class="fix">Everywhere</div></div>) +
            %(<svg viewBox="0 0 10 10"><image href="https://evil.example/x.png"/></svg><img src="https://evil.example/y.png">),
        css:
          ":host { height: 2000px !important; width: 3000px !important } * { display: block } " \
            ".fix { position: fixed; inset: 0; z-index: 99999; background: red } .big { height: 5000px } " \
            "@keyframes jl-in { from { opacity: 0 } } body, html, #main-outlet { display: none !important }",
      },
    ].to_json

    outside = []
    page.driver.with_playwright_page do |pw|
      pw.on(
        "request",
        ->(request) { outside << request.url unless request.url.start_with?(Discourse.base_url) },
      )
    end

    visit "/latest"
    expect(page).to have_css(".jt-lines .jl-app")
    expect(page).to have_css("#main-outlet .topic-list")
    expect(page).to have_css(".jt-lines__label", text: "Ad")

    space =
      page.evaluate_script(
        "(() => { const r = document.querySelector('.jt-lines').getBoundingClientRect(); return [r.width, r.height]; })()",
      )
    expect(space[1]).to be < 300
    expect(
      page.evaluate_script(
        "document.elementFromPoint(5, window.innerHeight - 5).closest('.jl-app') === null",
      ),
    ).to eq(true)
    expect(outside.select { it.include?("evil.example") }).to eq([])
  end

  it "hides the label and thumbs on the forum's own ads" do
    SiteSetting.jtech_ads_list = [
      {
        name: "own",
        enabled: true,
        headline: "Ours",
        card: %(<p class="x">Ours</p>),
        css: ".x{color:inherit}",
        house: true,
      },
    ].to_json
    sign_in(member)
    visit "/latest"
    expect(page).to have_css(".jt-lines .jl-app")
    expect(page).to have_no_css(".jt-lines__label")
    expect(page).to have_no_css(".jt-lines__thumb")
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
