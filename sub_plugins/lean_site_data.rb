# frozen_string_literal: true
# Jtech sub-plugin: less in the data every page preloads, where the browser
# never reads it there (lib/discourse_lean_site_data.rb). Loaded by
# Jtech/plugin.rb in the Plugin::Instance context.

require_relative "../lib/discourse_lean_site_data"

after_initialize do
  reloadable_patch do
    ::SiteCategorySerializer.prepend(DiscourseLeanSiteData::SiteCategorySerializerExtension)
  end

  # The site's category list is serialized once and cached
  on(:site_setting_changed) do |name, _old, _new|
    Site.clear_cache if name.to_s == "jtech_lean_category_types"
  end
end
