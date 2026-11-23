# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ads in the welcome area" do
  fab!(:member) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:admin)

  let(:key) { DiscourseJtechAds.key_for("spring") }
  let(:members_key) { DiscourseJtechAds.key_for("members-only") }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_ads_enabled = true
    SiteSetting.jtech_ads_list = [
      {
        name: "spring",
        enabled: true,
        headline: "<b>Spring</b> sale",
        text: "Ends Friday",
        audience: "everyone",
      },
      { name: "members-only", enabled: true, headline: "For members", audience: "members" },
    ].to_json
  end

  def lines
    get "/latest.json"
    expect(response.status).to eq(200)
    response.parsed_body.dig("topic_list", "jt_lines")
  end

  it "puts the ads for each person in the welcome list, under neutral keys" do
    data = lines
    expect(data["label"]).to eq("Ad")
    expect(data["items"].map { it["h"] }).to eq(["<b>Spring</b> sale"])
    expect(data["items"].first).not_to have_key("v")

    sign_in(member)
    expect(lines["items"].map { it["k"] }).to eq([key, members_key])
  end

  it "comes with the welcome pages' lists only, not every page's site data" do
    category = Fabricate(:category)
    topic = Fabricate(:post).topic

    get "/categories.json"
    expect(response.parsed_body.dig("category_list", "jt_lines", "items").map { it["h"] }).to eq(
      ["<b>Spring</b> sale"],
    )
    get "/categories_and_latest.json"
    expect(response.parsed_body.dig("topic_list", "jt_lines")).to be_present
    get "/top.json"
    expect(response.parsed_body.dig("topic_list", "jt_lines")).to be_present

    get "/site.json"
    expect(response.parsed_body).not_to have_key("jt_lines")
    get "/c/#{category.slug}/#{category.id}/l/latest.json"
    expect(response.parsed_body["topic_list"]).not_to have_key("jt_lines")
    get "/categories.json", params: { parent_category_id: category.id }
    expect(response.parsed_body["category_list"]).not_to have_key("jt_lines")
    get "/t/#{topic.id}.json"
    expect(response.body).not_to include("jt_lines")
  end

  it "sends nothing with ads off, or with Jtech off" do
    SiteSetting.jtech_ads_enabled = false
    expect(lines).to be_nil

    SiteSetting.jtech_ads_enabled = true
    SiteSetting.jtech_enabled = false
    expect(lines).to be_nil
  end

  it "shows visitors a changed ad straight away" do
    expect(lines["items"].first["h"]).to eq("<b>Spring</b> sale")
    SiteSetting.jtech_ads_list = [{ name: "summer", enabled: true, headline: "Summer" }].to_json
    expect(lines["items"].map { it["h"] }).to eq(["Summer"])
  end

  describe "thumbs" do
    it "needs a member" do
      put "/jtech-lines/#{key}.json", params: { value: 1 }
      expect(response.status).to eq(403)
    end

    it "sets, changes and takes back a member's thumb, one per member and ad" do
      sign_in(member)

      put "/jtech-lines/#{key}.json", params: { value: 1 }
      expect(response.parsed_body).to eq({ "v" => 1 })
      put "/jtech-lines/#{key}.json", params: { value: -1 }
      expect(DiscourseJtechAds::Vote.where(ad_key: key).pluck(:user_id, :value)).to eq(
        [[member.id, -1]],
      )
      expect(lines["items"].find { it["k"] == key }["v"]).to eq(-1)

      put "/jtech-lines/#{key}.json", params: { value: 0 }
      expect(response.parsed_body).to eq({ "v" => nil })
      expect(DiscourseJtechAds::Vote.count).to eq(0)
    end

    it "only takes thumbs on an ad the member can see" do
      SiteSetting.jtech_ads_list = [
        { name: "spring", enabled: true, headline: "Hi", audience: "visitors" },
      ].to_json
      sign_in(member)

      put "/jtech-lines/#{key}.json", params: { value: 1 }
      expect(response.status).to eq(404)
    end

    it "takes no thumbs on the forum's own (house) ads" do
      SiteSetting.jtech_ads_list = [
        { name: "spring", enabled: true, headline: "Hi", house: true },
      ].to_json
      sign_in(member)
      put "/jtech-lines/#{key}.json", params: { value: 1 }
      expect(response.status).to eq(404)
    end

    it "rejects other values" do
      sign_in(member)
      put "/jtech-lines/#{key}.json", params: { value: 5 }
      expect(response.status).to eq(400)
    end

    it "shows nobody counts on the ads, and admins who gave which thumb" do
      DiscourseJtechAds::Vote.create!(user: member, ad_key: key, value: 1)
      DiscourseJtechAds::Vote.create!(user: other, ad_key: key, value: -1)

      [member, admin].each do |user|
        sign_in(user)
        expect(lines["items"].find { it["k"] == key }).not_to have_key("n")
      end

      sign_in(member)
      put "/jtech-lines/#{key}.json", params: { value: 1 }
      expect(response.parsed_body).to eq({ "v" => 1 })
      get "/jtech-lines/votes.json"
      expect(response.status).to eq(403)

      sign_in(admin)
      get "/jtech-lines/votes.json"
      spring = response.parsed_body["ads"].find { it["name"] == "spring" }
      expect(spring).to include("up" => 1, "down" => 1)
      expect(spring["voters"].map { [it["username"], it["value"]] }).to contain_exactly(
        [member.username, 1],
        [other.username, -1],
      )
    end
  end

  describe "admin previews" do
    it "lists, makes and opens previews for admins only" do
      sign_in(member)
      get "/jtech-lines/preview.json"
      expect(response.status).to eq(403)
      post "/jtech-lines/preview.json", params: { name: "spring" }
      expect(response.status).to eq(403)

      sign_in(admin)
      get "/jtech-lines/preview.json"
      expect(response.parsed_body["names"]).to eq(%w[spring members-only])

      post "/jtech-lines/preview.json",
           params: {
             name: "draft",
             headline: "Draft",
             card: %(<p class="jl-lead">x</p>),
           }
      token = response.parsed_body["token"]
      get "/jtech-lines/preview/#{token}.json"
      expect(response.parsed_body).to include(
        "h" => "Draft",
        "c" => %(<p class="jl-lead">x</p>),
        "preview" => true,
      )

      sign_in(member)
      get "/jtech-lines/preview/#{token}.json"
      expect(response.status).to eq(403)
    end
  end
end
