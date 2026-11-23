# frozen_string_literal: true

require "rails_helper"

# The palettes every page preloads carry only the colours their previews and
# swatches draw from, not all of them.
RSpec.describe "Palettes in the site data" do
  fab!(:user)
  fab!(:theme)

  # A palette as rich as the theme's: every core colour plus a few of its own
  fab!(:palette) do
    colors =
      ColorScheme.base_colors.map { |name, hex| ColorSchemeColor.new(name:, hex:) } +
        %w[jt_extra_one jt_extra_two].map { ColorSchemeColor.new(name: it, hex: "123456") }
    Fabricate(:color_scheme, name: "Rich", user_selectable: true, color_scheme_colors: colors)
  end

  before do
    SiteSetting.jtech_enabled = true
    theme.update!(color_scheme_id: palette.id, dark_color_scheme_id: palette.id)
    SiteSetting.default_theme_id = theme.id
  end

  def site
    get "/site.json"
    expect(response.status).to eq(200)
    response.parsed_body
  end

  def color_names(scheme)
    scheme["colors"].map { it["name"] }
  end

  it "sends each palette with only the colours shown, to visitors and members" do
    [nil, user].each do |viewer|
      sign_in(viewer) if viewer
      data = site
      rich = data["user_color_schemes"].find { it["id"] == palette.id }

      expect(color_names(rich)).to match_array(DiscourseJtechTheme::Palettes::SHOWN)
      expect(rich).to include("name" => "Rich", "is_dark" => palette.is_dark?)
      expect(rich["colors"].find { it["name"] == "tertiary" }).to eq(
        "name" => "tertiary",
        "hex" => palette.colors.find { it.name == "tertiary" }.hex,
      )
      expect(color_names(data["default_light_color_scheme"])).to match_array(
        DiscourseJtechTheme::Palettes::SHOWN,
      )
      expect(color_names(data["default_dark_color_scheme"])).to match_array(
        DiscourseJtechTheme::Palettes::SHOWN,
      )
    end
  end

  it "sends every colour when switched off" do
    SiteSetting.jtech_lean_palettes = false
    rich = site["user_color_schemes"].find { it["id"] == palette.id }
    expect(color_names(rich)).to include("jt_extra_one", "jt_extra_two", "love")
  end

  it "leaves the cached list whole for when it's switched off again" do
    site
    SiteSetting.jtech_lean_palettes = false
    rich = site["user_color_schemes"].find { it["id"] == palette.id }
    expect(color_names(rich)).to include("jt_extra_one")
  end
end
