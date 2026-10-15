# frozen_string_literal: true

namespace :jtech do
  namespace :theme do
    desc "Install or re-import the JTech theme bundled with Jtech Tools (also after an admin deleted it)"
    task install: :environment do
      installer = DiscourseJtechTheme::Installer
      result =
        DistributedMutex.synchronize(installer::MUTEX_KEY, validity: 5.minutes) do
          installer.reinstall!
        end
      theme = installer.theme
      puts "JTech theme #{result}: id #{theme&.id}"
    end

    # rake jtech:theme:settings < theme-settings.yml (docs/setup/), the theme's
    # counterpart to core's site_settings:import
    desc "Set the JTech theme's settings from YAML on standard input"
    task settings: :environment do
      theme = DiscourseJtechTheme::Installer.theme
      abort "The JTech theme isn't installed: turn on jtech_theme_install first" if !theme

      YAML
        .safe_load(STDIN.read)
        .each do |name, value|
          theme.update_setting(name.to_sym, value)
          puts "#{name} set"
        end
      theme.save!
    end
  end
end
