# frozen_string_literal: true

module ::DiscourseJtechTheme
  # Installs the JTech theme bundled in themes/jtech, the way core installs its
  # own themes (db/fixtures/600_themes.rb → RemoteTheme.import_theme_from_directory).
  # It runs on every db:migrate, so a plugin update brings the theme up to date.
  #
  # It only ever installs or updates. Making JTech the default, letting users
  # pick it and attaching components stay admin decisions. If an admin deletes
  # the theme it stays deleted until they turn jtech_theme_install off and on
  # again, or run `rake jtech:theme:install`.
  module Installer
    STORE_KEY = "bundled_theme"
    MUTEX_KEY = "jtech_bundled_theme"

    # A JTech theme installed by hand before the plugin shipped it (from its old
    # Git repo) is recognised by these, and updated in place instead of getting
    # a second "JTech" next to it.
    THEME_NAME = "JTech"
    ABOUT_URL = "https://jtechforums.org"

    # Palettes people can choose (interface preferences, the sidebar's palette
    # menu) besides the theme's own light and dark defaults: JTech Dim (grey
    # instead of OLED black) and the colour pairs. Core only applies a palette
    # someone chose if it's user-selectable, and imported palettes never are;
    # each is switched on once, so an admin who turns one off again
    # (Customize → Colors) isn't overruled.
    OFFERED_PALETTES = [
      "JTech Dim",
      *[
        "Discourse",
        "Nord",
        "Catppuccin",
        "Rosé Pine",
        "Gruvbox",
        "Tokyo Night",
        "Everforest",
        "Paper",
        "Horizon",
      ].flat_map { |f| ["#{f} Light", "#{f} Dark"] },
    ].freeze

    def self.directory
      ENV["JTECH_THEME_DIR"].presence || File.expand_path("../../themes/jtech", __dir__)
    end

    # SHA256 over every file's relative path and bytes: updates are skipped
    # unless the bundled theme actually changed.
    def self.digest(dir = directory)
      sha = Digest::SHA256.new
      Dir
        .glob("**/*", base: dir)
        .sort
        .each do |path|
          full = File.join(dir, path)
          next if File.directory?(full)
          sha << path << "\0" << File.binread(full) << "\0"
        end
      sha.hexdigest
    end

    def self.state
      PluginStore.get(PLUGIN_NAME, STORE_KEY) || {}
    end

    def self.save_state(state)
      PluginStore.set(PLUGIN_NAME, STORE_KEY, state)
    end

    def self.theme
      id = state["theme_id"]
      id && Theme.find_by(id: id)
    end

    # Called from db/fixtures on every migrate. Never raises: a theme that
    # fails to import must not stop a rebuild.
    def self.sync!
      return :skipped_test if Rails.env.test? && ENV["JTECH_THEME_SEED"].blank?
      return :disabled if !DiscourseJtechTheme.enabled?

      result = DistributedMutex.synchronize(MUTEX_KEY, validity: 5.minutes) { sync_now }
      if %i[installed adopted updated].include?(result)
        puts "[jtech-tools] JTech theme #{result} (theme id #{state["theme_id"]})"
      end
      result
    rescue => e
      Rails.logger.error("[jtech-tools] JTech theme install failed: #{e.class}: #{e.message}")
      warn "[jtech-tools] JTech theme install failed: #{e.class}: #{e.message}"
      :failed
    end

    def self.sync_now
      current = state
      bundled = digest

      if current["theme_id"]
        return :removed if current["removed_at"]

        if !Theme.exists?(id: current["theme_id"])
          save_state(current.merge("removed_at" => Time.zone.now.iso8601))
          return :removed
        end

        return :unchanged if current["digest"] == bundled
        return install(theme_id: current["theme_id"], digest: bundled)
      end

      existing = adoptable_theme
      install(theme_id: existing&.id, digest: bundled, adopted: existing.present?)
    end

    # Runs when an admin turns jtech_theme_install on: a theme they deleted
    # comes back, otherwise it's a normal sync.
    def self.restore!
      current = state
      if current["theme_id"] && !Theme.exists?(id: current["theme_id"])
        save_state(current.except("theme_id", "removed_at"))
      end
      sync_now
    end

    # `rake jtech:theme:install`: re-imports even when nothing changed, and
    # brings back a deleted theme.
    def self.reinstall!
      current = state
      id = current["theme_id"] if current["theme_id"] && Theme.exists?(id: current["theme_id"])
      existing = id ? nil : adoptable_theme
      install(theme_id: id || existing&.id, digest: digest, adopted: existing.present?)
    end

    # Core links a RemoteTheme only for a Git import. A theme uploaded as a zip
    # or synced with the discourse_theme CLI has none, so its about_url is read
    # from about.json, which core keeps as a theme field for every install.
    def self.adoptable_theme
      themes = Theme.where(component: false, name: THEME_NAME).includes(:remote_theme).to_a
      about_json =
        ThemeField
          .where(theme_id: themes.map(&:id), target_id: Theme.targets[:about], name: "about")
          .pluck(:theme_id, :value)
          .to_h
      candidates =
        themes.select do |t|
          (about_url(about_json[t.id]) || t.remote_theme&.about_url) == ABOUT_URL
        end
      candidates.first if candidates.size == 1
    end

    def self.about_url(json)
      JSON.parse(json)["about_url"].presence if json.present?
    rescue JSON::ParserError
      nil
    end

    def self.install(theme_id:, digest:, adopted: false)
      # An adopted Git install would otherwise keep pulling the old repo over
      # this copy whenever that repo gets a commit (core's themes:update).
      Theme.find(theme_id).update!(remote_theme: nil) if adopted
      theme =
        RemoteTheme.import_theme_from_directory(
          directory,
          theme_id: theme_id,
          allow_out_of_sequence_migration: theme_id.present?,
        )
      save_state(
        "theme_id" => theme.id,
        "digest" => digest,
        "offered_palettes" => offer_palettes(theme),
      )
      Stylesheet::Manager.clear_theme_cache!
      return :adopted if adopted
      theme_id ? :updated : :installed
    end

    def self.offer_palettes(theme)
      offered = state["offered_palettes"] || []
      ColorScheme
        .where(theme_id: theme.id, name: OFFERED_PALETTES - offered)
        .find_each do |scheme|
          scheme.update!(user_selectable: true)
          offered += [scheme.name]
        end
      offered
    end
  end
end
