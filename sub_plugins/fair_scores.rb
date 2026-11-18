# frozen_string_literal: true
# Jtech sub-plugin: leaderboard points with daily caps
# (lib/discourse_fair_scores.rb). Instance_eval'd by plugin.rb in the
# Plugin::Instance context.
#
# Settings (config/settings.yml, jtech): jtech_fair_scores,
# jtech_fair_scores_replies_per_day, jtech_fair_scores_likes_per_person_per_day,
# jtech_fair_scores_likes_given_per_day

require_relative "../lib/discourse_fair_scores"

after_initialize { DiscourseFairScores.patch_gamification! }
