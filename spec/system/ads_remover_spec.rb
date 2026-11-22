# frozen_string_literal: true

require "rails_helper"

# The published "JTech Ad Remover" Chrome extension against the ad space:
# the ad still shows. Runs their files as they are, from a checkout of
# their repository (JTECH_AD_REMOVER_DIR), the way Chrome would: the
# stylesheet in the page from the start, page-hook.js in the page's world
# and content.js with chrome.dom.openOrClosedShadowRoot, which can see into
# closed shadow roots. .github/workflows/ad-remover-check.yml fetches their
# latest every day; when this fails, they've found a way around the
# fallback (jt-lines-fallback.gts), and it's our turn.
RSpec.describe "Ads against the ad remover extension", if: ENV["JTECH_AD_REMOVER_DIR"].present? do
  fab!(:member) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic)
  fab!(:post) { Fabricate(:post, topic: topic) }

  let(:dir) { Pathname.new(ENV["JTECH_AD_REMOVER_DIR"]) }
  let(:manifest) { JSON.parse(dir.join("manifest.json").read) }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_ads_enabled = true
    SiteSetting.jtech_ads_welcome_seconds = 0
    SiteSetting.jtech_ads_list = [
      {
        name: "spring",
        enabled: true,
        headline: "Spring sale",
        card: %(<div class="jl-stack"><h2 class="jl-title-xl">Spring sale</h2></div>),
        audience: "everyone",
      },
    ].to_json
    install_extension
  end

  # Their content scripts, in manifest order, at document start
  def install_extension
    scripts = manifest["content_scripts"]
    css = scripts.flat_map { it["css"] || [] }.map { dir.join(it).read }.join("\n")
    # document_start in Chrome: once the root element exists, before any
    # of the page's own scripts
    js = scripts.flat_map { it["js"] || [] }.map { |file| <<~JS }
            (function run() {
              if (!document.documentElement) {
                new MutationObserver((_, observer) => {
                  if (document.documentElement) { observer.disconnect(); run(); }
                }).observe(document, { childList: true });
                return;
              }
              #{dir.join(file).read}
            })();
          JS

    # chrome.dom.openOrClosedShadowRoot: an extension can open closed roots;
    # here every root attached is remembered for it. The extension's own
    # stylesheet isn't one of the page's sheets, as in Chrome.
    shim = <<~JS
      (() => {
        const roots = new WeakMap();
        const attach = Element.prototype.attachShadow;
        Element.prototype.attachShadow = function (init) {
          const root = attach.call(this, init);
          roots.set(this, root);
          return root;
        };
        window.chrome = window.chrome || {};
        window.chrome.dom = { openOrClosedShadowRoot: (el) => el.shadowRoot || roots.get(el) || null };
        window.__jtRoots = roots;
        const sheet = new CSSStyleSheet();
        sheet.replaceSync(#{css.to_json});
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      })();
    JS

    page.driver.with_playwright_page do |pw|
      ([shim] + js).each { |script| pw.add_init_script(script: script) }
    end
  end

  # The ad's headline, wherever it ended up, if a person can see it: in the
  # page, or in a shadow root, with a box of its own and nothing hiding it
  def ad_visible?
    page.evaluate_script(<<~JS)
      (() => {
        const seen = (el) => {
          for (let node = el; node; node = node.parentNode || node.host) {
            if (node.nodeType !== 1) continue;
            const s = getComputedStyle(node);
            if (s.display === "none" || s.visibility === "hidden" || Number(s.opacity) === 0) return false;
          }
          const box = el.getBoundingClientRect();
          return box.width > 0 && box.height > 0;
        };
        const found = [...document.querySelectorAll(".jl-title-xl")];
        for (const el of document.querySelectorAll("*")) {
          const root = window.__jtRoots.get(el);
          if (root) found.push(...root.querySelectorAll(".jl-title-xl"));
        }
        return found.some((el) => el.textContent.includes("Spring sale") && seen(el));
      })()
    JS
  end

  shared_examples "the ad shows" do
    it "for a visitor" do
      visit "/latest"
      expect(page).to have_css("#main-outlet .topic-list")
      try_until_success(timeout: 8) { expect(ad_visible?).to eq(true) }
    end

    it "for a member, who can still vote" do
      sign_in(member)
      visit "/latest"
      expect(page).to have_css("#main-outlet .topic-list")
      try_until_success(timeout: 8) { expect(ad_visible?).to eq(true) }
    end

    it "after moving around the forum" do
      visit topic.relative_url
      expect(page).to have_css("#post_1")
      find("#site-logo, .title a", match: :first).click
      expect(page).to have_css("#main-outlet .topic-list")
      try_until_success(timeout: 8) { expect(ad_visible?).to eq(true) }
    end
  end

  context "with core's theme" do
    include_examples "the ad shows"
  end

  context "with the JTech theme", if: ENV["JTECH_THEME_SPECS"].present? do
    fab!(:jtech_theme) do
      DiscourseJtechTheme::Installer.sync_now
      DiscourseJtechTheme::Installer.theme
    end

    before { jtech_theme.set_default! }

    include_examples "the ad shows"
  end
end
