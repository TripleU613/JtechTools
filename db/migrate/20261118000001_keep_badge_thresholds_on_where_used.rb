# frozen_string_literal: true

# jtech_badge_thresholds used to default to on, so a forum installing the
# plugin had core's badge ladders lowered without asking. It now defaults to
# off. A site already running Jtech kept the old default without storing it;
# store it on so nothing changes there.
class KeepBadgeThresholdsOnWhereUsed < ActiveRecord::Migration[7.2]
  def up
    jtech_on = DB.query_single(<<~SQL).first == "t"
      SELECT value FROM site_settings WHERE name = 'jtech_enabled'
    SQL
    return unless jtech_on && Migration::Helpers.existing_site?

    execute <<~SQL
      INSERT INTO site_settings (name, data_type, value, created_at, updated_at)
      VALUES ('jtech_badge_thresholds', 5, 't', NOW(), NOW())
      ON CONFLICT (name) DO NOTHING
    SQL
  end

  def down
  end
end
