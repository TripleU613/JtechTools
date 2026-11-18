# frozen_string_literal: true

require "rails_helper"
require_relative "../../db/migrate/20261118000001_keep_badge_thresholds_on_where_used"

RSpec.describe KeepBadgeThresholdsOnWhereUsed do
  def stored
    DB.query_single("SELECT value FROM site_settings WHERE name = 'jtech_badge_thresholds'").first
  end

  before do
    DB.exec("DELETE FROM site_settings WHERE name IN ('jtech_enabled', 'jtech_badge_thresholds')")
    Migration::Helpers.stubs(:existing_site?).returns(true)
  end

  def store_jtech(value)
    DB.exec(<<~SQL, value:)
      INSERT INTO site_settings (name, data_type, value, created_at, updated_at)
      VALUES ('jtech_enabled', 5, :value, NOW(), NOW())
    SQL
  end

  it "keeps the thresholds on for a site running Jtech" do
    store_jtech("t")
    described_class.new.up
    expect(stored).to eq("t")
  end

  it "leaves a site that turned the thresholds off alone" do
    store_jtech("t")
    DB.exec(<<~SQL)
      INSERT INTO site_settings (name, data_type, value, created_at, updated_at)
      VALUES ('jtech_badge_thresholds', 5, 'f', NOW(), NOW())
    SQL
    described_class.new.up
    expect(stored).to eq("f")
  end

  it "stores nothing where Jtech isn't on, so the new default applies" do
    described_class.new.up
    expect(stored).to be_nil

    store_jtech("f")
    described_class.new.up
    expect(stored).to be_nil
  end

  it "stores nothing on a new site" do
    store_jtech("t")
    Migration::Helpers.stubs(:existing_site?).returns(false)
    described_class.new.up
    expect(stored).to be_nil
  end
end
