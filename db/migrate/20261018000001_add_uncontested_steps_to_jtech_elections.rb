# frozen_string_literal: true

# Nominations that close with no more candidates than seats have nothing to
# vote on: they stay open a few days longer, once, and if it's still so
# there's no Vote Week. When each happened, so neither happens twice and the
# page can say why.
class AddUncontestedStepsToJtechElections < ActiveRecord::Migration[7.2]
  def change
    add_column :jtech_elections, :nominations_extended_at, :datetime
    add_column :jtech_elections, :vote_skipped_at, :datetime
  end
end
