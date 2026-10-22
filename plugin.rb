# frozen_string_literal: true

# name: jtech-tools
# about: Jtech Tools — the JTech Forums all-in-one plugin: moderator tools, Mini-mod, Dislike, the Disteleplus Telegram bridge, REQ-PM, listing format for sale threads, mod elections, Dumbcourse, smart search, desktop pop-ups, Another SMTP, translator tweaks and the JTech theme.
# version: 0.5.0
# authors: TripleU, Shalom_Karr, Ars18
# url: https://github.com/TripleU613/JtechTools
# required_version: 3.0.0

# Smart-search synonym backend — rwordnet ships the WordNet lexical DB
# (~117K English words, ~8MB) inside the gem. Pure-Ruby, no external
# C extensions, no network calls.
gem "rwordnet", "2.0.0", require: false

# Master gate. Each sub-plugin keeps its own enable setting (e.g.
# discourse_no_likes_enabled, mini_mod_enabled, mod_categories_enabled,
# dumbcourse_enabled, discourse_another_email_enabled, smart_search_enabled,
# reqpm_enabled, listing_format_enabled, mod_elections_enabled) for
# fine-grained control.
enabled_site_setting :jtech_enabled

# Load each sub-plugin's body in the Plugin::Instance context so that all
# Discourse plugin DSL methods — after_initialize, on(:event), register_asset,
# register_svg_icon, add_to_serializer, reloadable_patch, register_html_builder,
# require_relative for nested lib files, etc. — work exactly as they did in the
# original standalone plugin.
#
# Each sub_*.rb file is a faithful copy of its original plugin.rb body
# (magic-header comments and the top-level enabled_site_setting call stripped).
# Settings, locales, lib/, app/, db/migrate, and assets/ from every sub-plugin
# have been merged into this plugin's standard Discourse layout.
%w[
  dislike
  another_smtp
  mini_mod
  mod_categories
  dumbcourse
  translator_tweaks
  smart_search
  popup_notifications
  disteleplus
  reqpm
  listing_format
  jtech_theme
  mod_elections
  trust_level_flair
  jtech_badges
].each do |sub|
  path = File.expand_path("sub_plugins/#{sub}.rb", __dir__)
  instance_eval(File.read(path), path, 1)
end
