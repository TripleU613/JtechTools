# frozen_string_literal: true

require "rails_helper"

# The forum sidebar's Dumbcourse link: a section of its own, unless one of
# the sidebar's own sections already links there (it showed twice).
RSpec.describe "Dumbcourse sidebar link" do
  fab!(:user)

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.dumbcourse_enabled = true
    sign_in(user)
  end

  it "has a section of its own" do
    visit("/latest")
    expect(page).to have_css(".sidebar-section[data-section-name='dumbcourse'] a[href='/dumb']")
  end

  it "stands down when another sidebar section links to Dumbcourse" do
    section = Fabricate(:sidebar_section, user: user, title: "Mine")
    Fabricate(
      :sidebar_section_link,
      sidebar_section: section,
      linkable: Fabricate(:sidebar_url, name: "Dumbcourse", value: "/dumb"),
    )
    visit("/latest")
    expect(page).to have_css(".sidebar-section-link[href='/dumb']", count: 1)
    expect(page).to have_no_css(".sidebar-section[data-section-name='dumbcourse']")
  end
end
