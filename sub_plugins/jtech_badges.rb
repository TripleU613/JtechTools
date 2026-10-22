# frozen_string_literal: true
# Jtech sub-plugin: badges for taking part in the other modules
# (lib/discourse_jtech_badges.rb). Instance_eval'd by plugin.rb in the
# Plugin::Instance context, after the modules whose tables and switches it
# reads; db/fixtures/jtech_badges.rb seeds them on every rebuild.

require_relative "../lib/discourse_jtech_badges"

after_initialize do
  on(:site_setting_changed) do |name, _old_val, _new_val|
    if name == :jtech_enabled
      DiscourseJtechBadges::SWITCHES.each_key { |set| DiscourseJtechBadges.refresh!(set) }
    elsif (set = DiscourseJtechBadges::SETTINGS[name])
      DiscourseJtechBadges.refresh!(set)
    end
  end
end
