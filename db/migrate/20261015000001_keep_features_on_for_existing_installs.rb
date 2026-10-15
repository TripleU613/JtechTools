# frozen_string_literal: true

# A new install starts with everything off. These all defaulted to on, so a
# forum that already ran the plugin without setting them would have lost
# every feature: it gets the old value written as its own setting instead.
#
# "Already ran the plugin" is the plugin's first migration having run more
# than an hour before this one (a fresh install runs them all in one go), or
# any of the plugin's settings already set (nobody can set them before the
# plugin is there). A forum adding the plugin today starts with everything
# off, however old the forum is.
class KeepFeaturesOnForExistingInstalls < ActiveRecord::Migration[7.2]
  SETTINGS = %w[
    jtech_enabled
    jtech_theme_install
    jtech_app_icon
    discourse_no_likes_enabled
    mod_categories_enabled
    mod_whisper_enabled
    mod_notification_type_filter_enabled
    mod_auto_mark_notifications_seen
    translator_tweaks_enabled
    popup_notifications_enabled
    dumbcourse_enabled
    reqpm_enabled
    listing_format_enabled
  ]

  def up
    installed_before = DB.query_single(<<~SQL).first
      SELECT 1 FROM schema_migration_details
       WHERE version = '20260225000001'
         AND created_at < NOW() - INTERVAL '1 hour'
      UNION ALL
      SELECT 1 FROM site_settings
       WHERE name ~ '^(jtech|disteleplus|dumbcourse|reqpm|listing_format|mini_mod|smart_search|discourse_another_email|discourse_no_likes|dislike|popup_notifications|translator_tweaks|mod_elections)_'
      LIMIT 1
    SQL
    return if !installed_before

    # data_type 5 is bool; a setting already stored keeps its value
    SETTINGS.each { |name| execute <<~SQL }
        INSERT INTO site_settings (name, data_type, value, created_at, updated_at)
        VALUES ('#{name}', 5, 't', NOW(), NOW())
        ON CONFLICT (name) DO NOTHING
      SQL
  end

  def down
  end
end
