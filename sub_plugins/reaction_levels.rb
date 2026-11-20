# frozen_string_literal: true
# Jtech sub-plugin: higher trust levels unlock more reaction emojis
# (lib/discourse_reaction_levels.rb, docs/features/reaction-levels.md).
# Instance_eval'd by plugin.rb in the Plugin::Instance context.
#
# Settings (config/settings.yml, jtech_reaction_levels): jtech_reaction_levels_enabled,
# jtech_reaction_levels_tl0 … jtech_reaction_levels_tl4

require_relative "../lib/discourse_reaction_levels"

after_initialize do
  if defined?(::DiscourseReactions::CustomReactionsController)
    ::DiscourseReactions::CustomReactionsController.prepend(DiscourseReactionLevels::ToggleGate)
  end

  # The reactions this person may use; absent when nothing is held back
  # for them
  add_to_serializer(
    :current_user,
    :jt_reactions,
    include_condition: -> { !DiscourseReactionLevels.allowed_for(object).nil? },
  ) { DiscourseReactionLevels.allowed_for(object) }
end
