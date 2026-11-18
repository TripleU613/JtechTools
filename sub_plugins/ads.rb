# frozen_string_literal: true
# Jtech sub-plugin: ads in the home page's welcome area
# (lib/discourse_jtech_ads.rb, docs/features/ads.md). Instance_eval'd by
# plugin.rb in the Plugin::Instance context.
#
# Settings (config/settings.yml, jtech_ads): jtech_ads_enabled,
# jtech_ads_rotate_seconds, jtech_ads_label, jtech_ads_list

require_relative "../lib/discourse_jtech_ads"

register_asset "stylesheets/lines.scss"
register_svg_icon "thumbs-up"
register_svg_icon "thumbs-down"

after_initialize do
  # Inside the page's preloaded site data: no request of the ads' own
  add_to_serializer(:site, :jt_lines, include_condition: -> { DiscourseJtechAds.enabled? }) do
    DiscourseJtechAds.payload(scope)
  end

  # Visitors' site data is cached; a changed ad reaches them right away
  on(:site_setting_changed) do |name, _old, _new|
    DiscourseJtechAds.clear_cache! if name.to_s.start_with?("jtech_ads_") || name == :jtech_enabled
  end
end
