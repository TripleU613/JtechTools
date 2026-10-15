# frozen_string_literal: true

require_relative "../../db/migrate/20261015000001_keep_features_on_for_existing_installs"

# A new install starts with every feature off; the specs run with them on, as
# the forum does (db/migrate/20261015000001 keeps them on there). Specs about
# a feature being off switch it off themselves.
#
# On is made their default for the run, as core does for Gravatar downloads
# (spec/support/site_settings_provider.rb): each example's reset lands on it,
# and fab! blocks see it. A per-example hook can't do it: one registered late
# runs after a spec's own before, one registered early before core's reset.
RSpec.configure do |config|
  config.before(:suite) do
    KeepFeaturesOnForExistingInstalls::SETTINGS.each do |name|
      SiteSetting.defaults.set_regardless_of_locale(name.to_sym, true)
    end
    SiteSetting.refresh!
  end
end
