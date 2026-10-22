# frozen_string_literal: true

# A vote now counts as much as the voter's trust level up to 3, so trust
# level 4 counts 3 (DiscourseModElections::Roll::MAX_WEIGHT). An election
# whose count nobody has previewed yet takes the cap on its voter list and
# its ballots; a previewed or published count stays exactly as it was.
class CapElectionVoteWeights < ActiveRecord::Migration[7.2]
  # scheduled, nominating, voting, closed
  UNCOUNTED = "e.status IN (0, 1, 2, 3) AND e.previewed_at IS NULL"

  def up
    %w[jtech_election_voters jtech_election_ballots].each { |table| execute(<<~SQL) }
      UPDATE #{table} t
      SET weight = 3
      FROM jtech_elections e
      WHERE e.id = t.election_id AND t.weight > 3 AND #{UNCOUNTED}
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
