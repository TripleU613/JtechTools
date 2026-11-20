# frozen_string_literal: true

# Reaction levels: higher trust levels unlock more reaction emojis
# (docs/features/reaction-levels.md). discourse-reactions has one list of
# reactions for everyone; this holds some of them back until a trust level.
#
# Each trust level has a list. A reaction listed at a level is unlocked
# there and at every level above it. A reaction enabled in
# discourse-reactions but listed at no level stays open to everyone, so only
# the ones held back need listing. The main reaction (the like) is always
# open, and staff have them all. Only ever narrows core: the picker hides
# what isn't unlocked, and the server refuses it.
module ::DiscourseReactionLevels
  LEVELS = (0..4).freeze

  class << self
    def enabled?
      SiteSetting.jtech_enabled && SiteSetting.jtech_reaction_levels_enabled &&
        defined?(::DiscourseReactions) && SiteSetting.discourse_reactions_enabled
    end

    def list(level)
      SiteSetting
        .get(:"jtech_reaction_levels_tl#{level}")
        .to_s
        .split("|")
        .map(&:strip)
        .reject(&:empty?)
    end

    # emoji => the lowest trust level it's listed at
    def levels
      LEVELS.reverse_each.each_with_object({}) { |level, map| list(level).each { map[it] = level } }
    end

    def enabled_reactions
      SiteSetting
        .discourse_reactions_enabled_reactions
        .to_s
        .split("|")
        .map(&:strip)
        .reject(&:empty?)
    end

    def main_reaction
      SiteSetting.discourse_reactions_reaction_for_like
    end

    # The reactions this person may use, or nil when nothing is held back
    # for them (feature off, no user, staff)
    def allowed_for(user)
      return nil if !enabled? || user.nil? || user.staff?

      map = levels
      trust = user.trust_level.to_i
      ([main_reaction] + enabled_reactions).uniq.select do |emoji|
        level = map[emoji]
        emoji == main_reaction || level.nil? || level <= trust
      end
    end

    def allowed?(user, reaction)
      allowed = allowed_for(user)
      allowed.nil? || allowed.include?(reaction.to_s)
    end

    # What each trust level ends up with, for the admin tab
    def table
      map = levels
      enabled = ([main_reaction] + enabled_reactions).uniq
      rows =
        LEVELS.map do |level|
          {
            level:,
            unlocks: enabled.select { map[it] == level },
            all: enabled.select { it == main_reaction || map[it].nil? || map[it] <= level },
          }
        end
      {
        rows:,
        everyone: enabled.select { it == main_reaction || map[it].nil? },
        not_enabled: map.keys - enabled,
      }
    end
  end

  # Prepended onto discourse-reactions' controller: refuse a reaction the
  # person's trust level hasn't unlocked. Taking back one they already gave
  # is always allowed.
  module ToggleGate
    def toggle
      reaction = params[:reaction].to_s
      if !::DiscourseReactionLevels.allowed?(current_user, reaction) &&
           !::DiscourseReactionLevels::ToggleGate.reacted?(current_user, params[:post_id], reaction)
        level = ::DiscourseReactionLevels.levels[reaction]
        return(
          render_json_error(I18n.t("jtech_reaction_levels.locked", reaction:, level:), status: 403)
        )
      end
      super
    end

    def self.reacted?(user, post_id, reaction)
      ::DiscourseReactions::ReactionUser
        .joins(:reaction)
        .where(user_id: user.id, post_id: post_id.to_i)
        .where(discourse_reactions_reactions: { reaction_value: reaction })
        .exists?
    end
  end
end
