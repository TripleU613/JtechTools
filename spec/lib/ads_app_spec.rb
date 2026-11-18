# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseJtechAds::App do
  describe ".clean_css" do
    it "keeps CSS that loads nothing" do
      css =
        ".x { color: var(--jl-fg); animation: spin 2s infinite } @keyframes spin { to { rotate: 1turn } }"
      expect(described_class.clean_css(css)).to eq([css, nil])
    end

    it "refuses, whole, anything that could load from somewhere" do
      [
        ".x { background: url(https://evil.example/x.png) }",
        ".x { background: URL( //evil.example/x ) }",
        ".x { background: image-set('a.png' 1x) }",
        "@import 'https://evil.example/x.css';",
        "@font-face { font-family: x; src: local(x) }",
        ".x { background: u\\72l(https://evil.example) }",
        ".x { behavior: url(x.htc) }",
        "@namespace svg url(http://www.w3.org/2000/svg);",
        ".x { color: red } </style><script>",
      ].each do |css|
        cleaned, reason = described_class.clean_css(css)
        expect(cleaned).to be_nil, "kept: #{css}"
        expect(reason).to be_present
      end
    end
  end

  describe ".clean_html" do
    it "keeps any classes and safe SVG, and drops what can load or run" do
      html =
        %(<div class="hero spin"><svg viewBox="0 0 10 10"><defs><linearGradient id="g"><stop offset="0" stop-color="red"/></linearGradient></defs>) +
          %(<circle cx="5" cy="5" r="4" fill="url(#g)" onclick="x()"/><image href="https://evil.example/x.png"/>) +
          %(<use href="https://evil.example/s.svg#x"/><rect fill="url(https://evil.example/p)"/></svg>) +
          %(<img src="x.png"><iframe src="//x"></iframe><form><input></form><a href="javascript:x">j</a><a href="/about">ok</a></div>)

      cleaned, notes = described_class.clean_html(html)

      expect(cleaned).to include(%(<div class="hero spin">), %(fill="url(#g)"), %(<a href="/about"))
      expect(cleaned).not_to include(
        "evil",
        "onclick",
        "<img",
        "<iframe",
        "<form",
        "<input",
        "javascript:",
      )
      expect(notes).to include(
        "<image>",
        "<use>",
        "<img>",
        "<iframe>",
        "<form>",
        "attribute onclick",
      )
    end
  end

  describe "in the site data" do
    fab!(:member, :user)

    before do
      SiteSetting.jtech_enabled = true
      SiteSetting.jtech_ads_enabled = true
    end

    it "sends an app's CSS, and marks house and welcome ads" do
      SiteSetting.jtech_ads_list = [
        {
          name: "app",
          enabled: true,
          headline: "App",
          card: %(<p class="x">Hi</p>),
          css: ".x{color:red}",
          house: true,
          intro: true,
        },
        {
          name: "bad",
          enabled: true,
          headline: "Bad",
          card: %(<p class="x jl-lead">Hi</p>),
          css: ".x{background:url(//e.example)}",
        },
      ].to_json

      items = DiscourseJtechAds.payload(Guardian.new(member))[:items]
      expect(items.first).to include(
        c: %(<p class="x">Hi</p>),
        x: ".x{color:red}",
        o: true,
        i: true,
      )
      # refused CSS: the card is cleaned as a kit card instead
      expect(items.second).to include(c: %(<p class="jl-lead">Hi</p>), x: nil, o: nil)
    end
  end
end
