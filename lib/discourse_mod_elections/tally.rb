# frozen_string_literal: true

module DiscourseModElections
  # Runs the count on an election's ballots: candidates still running,
  # ballots not set aside, the lot seed drawn when voting closed.
  module Tally
    def self.count(election, excluded: [])
      ballots =
        election
          .ballots
          .counted
          .pluck(:weight, :ranking)
          .map { |weight, ranking| Stv::Ballot.new(weight, ranking) }
      Stv.count(
        candidates: election.candidates.running.order(:id).pluck(:id),
        ballots: ballots,
        seats: election.seats,
        seed: election.seed || election.id,
        excluded: excluded,
      )
    end

    # The count as stored: every stage in plain numbers, candidates by id.
    # Names are looked up when it's shown (Presenter.result_json), so a
    # renamed or anonymized account never lingers under its old name.
    def self.serialize(election, result)
      candidates = election.candidates.where(id: result.stages.first&.tallies&.keys || [])
      {
        "seats" => result.seats,
        "quota" => number(result.quota),
        "total" => number(result.total),
        "ballots" => result.ballots,
        "outcome" => result.outcome.to_s,
        "seed" => result.seed,
        "elected" => result.elected,
        "exhausted" => number(result.exhausted),
        "candidates" =>
          candidates.map do |candidate|
            {
              "id" => candidate.id,
              "user_id" => candidate.user_id,
              "incumbent" => candidate.incumbent,
            }
          end,
        "stages" =>
          result.stages.map do |stage|
            {
              "number" => stage.number,
              "action" => stage.action.to_s,
              "candidate" => stage.candidate,
              "excluded" => stage.excluded,
              "tallies" => stage.tallies.transform_keys(&:to_s).transform_values { |v| number(v) },
              "exhausted" => number(stage.exhausted),
              "elected" => stage.elected,
              "ties" =>
                stage.ties.map do |tie|
                  {
                    "purpose" => tie.purpose.to_s,
                    "method" => tie.method.to_s,
                    "among" => tie.among,
                    "chosen" => tie.chosen,
                    "decided_at" => tie.decided_at,
                  }
                end,
            }
          end,
      }
    end

    def self.number(value)
      value.to_r.round(4).to_f
    end
  end
end
