# frozen_string_literal: true
# Jtech sub-plugin: trust level flair. Instance_eval'd by plugin.rb in the
# Plugin::Instance context. Everyone without a flair of their own shows their
# trust level group's (lib/discourse_trust_level_flair.rb).
#
# Setting (config/settings.yml, jtech): jtech_trust_level_flair

require_relative "../lib/discourse_trust_level_flair"

after_initialize do
  # Core fires these before it moves the user into their new trust level
  # group; the job runs after, once they're in it.
  on(:user_promoted) do |args|
    next unless DiscourseTrustLevelFlair.enabled?
    Jobs.enqueue(:jtech_trust_level_flair, user_ids: [args[:user_id]])
  end

  on(:user_created) do |user|
    next unless DiscourseTrustLevelFlair.enabled?
    Jobs.enqueue(:jtech_trust_level_flair, user_ids: [user.id])
  end

  on(:site_setting_changed) do |name, _old_val, new_val|
    if name == :jtech_trust_level_flair && new_val && SiteSetting.jtech_enabled
      Jobs.enqueue(:jtech_trust_level_flair)
    end
  end
end
