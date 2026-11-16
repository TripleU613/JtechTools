# frozen_string_literal: true

require "rails_helper"
require_relative "../../db/migrate/20261104000001_switch_whispers_off"

RSpec.describe SwitchWhispersOff do
  def stored
    DB.query_single("SELECT value FROM site_settings WHERE name = 'mod_whisper_enabled'")
  end

  it "drops a forum's stored value, so whispers fall back to their default: off" do
    DB.exec(<<~SQL)
      INSERT INTO site_settings (name, data_type, value, created_at, updated_at)
      VALUES ('mod_whisper_enabled', 5, 't', NOW(), NOW())
      ON CONFLICT (name) DO UPDATE SET value = 't'
    SQL

    described_class.new.up

    expect(stored).to be_empty
  end
end
