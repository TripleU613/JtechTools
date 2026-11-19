# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseJtechAds::Manager do
  fab!(:admin)

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.jtech_ads_list = "[]"
  end

  def names
    JSON.parse(SiteSetting.jtech_ads_list).map { it["name"] }
  end

  it "saves, replaces in place and deletes ads through the setting, logged" do
    described_class.save!({ name: "a", headline: "A" }, by: admin)
    described_class.save!({ name: "b", headline: "B" }, by: admin)
    described_class.save!({ name: "a", headline: "A2", enabled: false }, by: admin)

    expect(names).to eq(%w[a b])
    expect(described_class.entries.first).to include("headline" => "A2", "enabled" => false)
    expect(UserHistory.where(acting_user_id: admin.id, subject: "jtech_ads_list").count).to eq(3)

    described_class.delete!("a", by: admin)
    expect(names).to eq(%w[b])
    expect { described_class.delete!("nope", by: admin) }.to raise_error(described_class::Error)
  end

  it "refuses an ad without a name or headline, and unknown settings" do
    expect { described_class.save!({ headline: "x" }, by: admin) }.to raise_error(
      described_class::Error,
    )
    expect { described_class.save!({ name: "x" }, by: admin) }.to raise_error(
      described_class::Error,
    )
    expect { described_class.configure!({ "colour" => 1 }, by: admin) }.to raise_error(
      described_class::Error,
    )
  end

  it "configures the settings" do
    described_class.configure!(
      { "enabled" => true, "rotate_seconds" => 30, "label" => "Sponsored" },
      by: admin,
    )
    expect(described_class.settings).to include(
      "enabled" => true,
      "rotate_seconds" => 30,
      "label" => "Sponsored",
    )
  end

  it "reports what cleaning drops from a card" do
    report =
      described_class.report(
        name: "x",
        headline: "Hi",
        card:
          %(<div class="jl-split evil" style="color:red" id="x"><img src="a.png"><p class="jl-lead">ok</p></div>),
      )

    expect(report[:card]).to eq(%(<div class="jl-split"><p class="jl-lead">ok</p></div>))
    expect(report[:dropped]).to include("class evil", "attribute style", "attribute id", "<img>")
  end

  it "keeps a preview for an admin, for saved ads and drafts" do
    described_class.save!({ name: "spring", headline: "Spring", enabled: false }, by: admin)

    saved = described_class.preview!(name: "spring")
    expect(saved[:url]).to include("?jl_preview=#{saved[:token]}")
    expect(described_class.preview_line(saved[:token])).to include(h: "Spring", preview: true)

    draft =
      described_class.preview!(
        entry: {
          "name" => "draft",
          "headline" => "Draft",
          "card" => %(<h2 class="jl-title">Big</h2>),
        },
      )
    expect(described_class.preview_line(draft[:token])[:c]).to eq(%(<h2 class="jl-title">Big</h2>))
    expect(described_class.preview_line("0" * 24)).to be_nil
    expect(described_class.preview_line("nope")).to be_nil
  end
end
