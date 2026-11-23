# frozen_string_literal: true

require "rails_helper"

# The categories every page preloads say which types they are, without each
# type's full definition; the category editor still gets all of it.
RSpec.describe "Category types in the site data" do
  fab!(:admin)
  fab!(:category)

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.enable_simplified_category_creation = true
    Site.clear_cache
  end

  def site_types(id)
    get "/site.json"
    expect(response.status).to eq(200)
    response.parsed_body["categories"].find { it["id"] == id }["category_types"]
  end

  it "sends each type's id, name, title and icon only" do
    types = site_types(category.id)
    expect(types.keys).to include("discussion")
    expect(types["discussion"].keys).to match_array(%w[id name title icon svg_icon])
    expect(types["discussion"]["id"]).to eq("discussion")
  end

  it "still gives the category editor the full definitions" do
    sign_in(admin)
    get "/c/#{category.slug}/find_by_slug.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("category", "category_types", "discussion")).to include(
      "configuration_schema",
      "description",
    )
  end

  it "sends the full definitions when switched off" do
    site_types(category.id)
    SiteSetting.jtech_lean_category_types = false
    expect(site_types(category.id)["discussion"]).to include("configuration_schema")
  end
end
