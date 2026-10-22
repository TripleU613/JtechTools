# frozen_string_literal: true
# Jtech sub-plugin: badge thresholds sized for JTech
# (lib/discourse_badge_thresholds.rb). Instance_eval'd by plugin.rb in the
# Plugin::Instance context; db/fixtures/jtech_badge_thresholds.rb applies them
# on every rebuild, after core re-seeds its badges.
#
# Setting (config/settings.yml, jtech): jtech_badge_thresholds

require_relative "../lib/discourse_badge_thresholds"

after_initialize do
  on(:site_setting_changed) do |name, _old_val, new_val|
    DiscourseBadgeThresholds.apply! if name == :jtech_badge_thresholds && new_val
  end
end
