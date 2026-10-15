# frozen_string_literal: true

require_relative "../../db/migrate/20261015000001_keep_features_on_for_existing_installs"

# A new install starts with every feature off; the specs run with them on, as
# the forum does (db/migrate/20261015000001 keeps them on there). Specs about
# a feature being off switch it off themselves.
#
# Registered from before(:suite) so it runs after core's per-example
# TestSetup (which resets site settings) rather than before it.
RSpec.configure do |config|
  config.before(:suite) do
    switch_on = -> do
      KeepFeaturesOnForExistingInstalls::SETTINGS.each do |name|
        SiteSetting.set(name, true) if SiteSetting.respond_to?(name)
      end
    end

    RSpec.configure do |late|
      # first, so a spec's own before can switch one off, and before each
      # group too, for what its fab! blocks create
      late.prepend_before(:context) { switch_on.call }
      late.prepend_before(:each) { switch_on.call }
    end
  end
end
