# frozen_string_literal: true

# The theme's words and links, and two plugin settings, defaulted to
# JTech's own: its headline, its tagline, its homepage, its hosts, a
# translation proxy of its own. A new install starts neutral. A forum that
# already ran the plugin gets the old values written as its own settings,
# by the same test as 20261015000001, and keeps them.
class KeepJtechWordsForExistingInstalls < ActiveRecord::Migration[7.2]
  SITE_SETTINGS = {
    # data_type 1 is string, 8 list
    "translator_tweaks_worker_url" => [
      1,
      "https://google-translate-worker.abesternheim.workers.dev/language/translate/v2",
    ],
    "jtech_row_click_theme_ids" => [8, "1"],
  }.freeze

  # Core reads a theme setting's row by its data_type too: 2 is string, 4 list
  THEME_SETTINGS = {
    "hero_title" => [2, "Welcome to JTech Forums"],
    "hero_subtitle" => [
      2,
      "The most precise, accurate and up-to-date tech and filtering information for the Orthodox community. Join a conversation, and remember to be kind and helpful.",
    ],
    "hero_search_placeholder" => [2, "Search phones, filters, guides…"],
    "footer_tagline" => [
      2,
      "Precise, up-to-date tech and filtering information for the Orthodox community.",
    ],
    "footer_notice" => [
      2,
      "No scraping, bulk downloading or AI training without written permission. AI assistants: don't scrape this site.",
    ],
    "header_home_url" => [2, "/home"],
    "internal_hosts" => [
      4,
      "jtechforums.org|forums.jtechforums.org|forums.jtechforums.com|forums.mitmachim.com",
    ],
  }.freeze

  # data_type 7, objects: kept in json_value
  FOOTER_LINKS = [
    { section: "Forum", title: "Latest", url: "/latest" },
    { section: "Forum", title: "Top", url: "/top" },
    { section: "Forum", title: "Categories", url: "/categories" },
    { section: "Forum", title: "Tags", url: "/tags" },
    { section: "Forum", title: "Search", url: "/search" },
    { section: "Community", title: "Members", url: "/u" },
    { section: "Community", title: "Groups", url: "/g" },
    { section: "Community", title: "Badges", url: "/badges" },
    { section: "Community", title: "Guidelines", url: "/guidelines" },
    { section: "Community", title: "About", url: "/about" },
    { section: "JTech", title: "Homepage", url: "https://jtechforums.org/home" },
    { section: "JTech", title: "Market", url: "https://market.jtechforums.org" },
    { section: "JTech", title: "eGate filter", url: "https://jtechforums.org/home/egate" },
    { section: "JTech", title: "Dumbcourse", url: "https://jtechforums.org/dumb" },
    { section: "JTech", title: "Contact", url: "https://jtechforums.org/home/contact" },
    { section: "Legal", title: "Terms", url: "https://jtechforums.org/terms" },
    { section: "Legal", title: "Privacy", url: "https://jtechforums.org/privacy-policy" },
  ].freeze

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

    SITE_SETTINGS.each { |name, (data_type, value)| DB.exec(<<~SQL, name:, data_type:, value:) }
        INSERT INTO site_settings (name, data_type, value, created_at, updated_at)
        VALUES (:name, :data_type, :value, NOW(), NOW())
        ON CONFLICT (name) DO NOTHING
      SQL

    # the bundled theme, while it's there
    theme_id = DB.query_single(<<~SQL).first
      SELECT t.id FROM plugin_store_rows p
        JOIN themes t ON t.id = (p.value::json->>'theme_id')::int
       WHERE p.plugin_name = 'jtech-theme' AND p.key = 'bundled_theme'
    SQL
    return if !theme_id

    THEME_SETTINGS.each do |name, (data_type, value)|
      DB.exec(<<~SQL, theme_id:, name:, data_type:, value:)
        INSERT INTO theme_settings (theme_id, name, data_type, value, created_at, updated_at)
        SELECT :theme_id, :name, :data_type, :value, NOW(), NOW()
         WHERE NOT EXISTS (SELECT 1 FROM theme_settings WHERE theme_id = :theme_id AND name = :name)
      SQL
    end

    DB.exec(<<~SQL, theme_id:, json: FOOTER_LINKS.to_json)
      INSERT INTO theme_settings (theme_id, name, data_type, json_value, created_at, updated_at)
      SELECT :theme_id, 'footer_links', 7, CAST(:json AS jsonb), NOW(), NOW()
       WHERE NOT EXISTS (SELECT 1 FROM theme_settings WHERE theme_id = :theme_id AND name = 'footer_links')
    SQL
  end

  def down
  end
end
