# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseDumbcourse::Palette do
  # The stylesheet's own colours are what browsers without custom properties
  # get, and everyone before the page's palette applies: they must be JTech
  # Dark and JTech Light as this maps them, or the two drift apart.
  it "maps JTech Dark and JTech Light to the stylesheet's own colour tokens" do
    schemes =
      JSON.parse(File.read(File.expand_path("../../themes/jtech/about.json", __dir__)))[
        "color_schemes"
      ]
    scss = File.read(File.expand_path("../../dumbcourse/styles/00-tokens.scss", __dir__))
    stylesheet = ->(selector) do
      scss[/#{Regexp.escape(selector)} \{(.*?)\}/m, 1].scan(/--([\w-]+): (#\h+);/).to_h
    end
    mapped = ->(name, dark) do
      scheme = Struct.new(:resolved_colors).new(schemes[name])
      described_class.tokens(scheme, dark: dark).transform_values { "##{_1}" }
    end

    expect(stylesheet.(":root")).to include(mapped.("JTech Dark", true))
    expect(stylesheet.("html.light")).to include(mapped.("JTech Light", false))
  end

  it "lets only hex colours through" do
    expect(
      described_class.declarations("bg" => "000", "fg" => "red;}body{x", "line" => "e0e0e0"),
    ).to eq("--bg:#000;--line:#e0e0e0;")
  end
end
