# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseModElections::Stv do
  def ballot(weight, *ranking)
    described_class::Ballot.new(weight, ranking)
  end

  def count(candidates, ballots, seats: 3, seed: 1, excluded: [])
    described_class.count(
      candidates: candidates,
      ballots: ballots,
      seats: seats,
      seed: seed,
      excluded: excluded,
    )
  end

  # The worked example on Wikipedia's "Single transferable vote" page.
  let(:food) do
    [
      ballot(4, "orange"),
      ballot(2, "pear", "orange"),
      ballot(8, "chocolate", "strawberry"),
      ballot(4, "chocolate", "burger"),
      ballot(1, "strawberry"),
      ballot(1, "burger"),
    ]
  end
  let(:dishes) { %w[orange pear chocolate strawberry burger] }

  it "elects the textbook winners, stage by stage" do
    result = count(dishes, food)

    expect(result.quota).to eq(6)
    expect(result.elected).to eq(%w[chocolate orange strawberry])
    expect(result.stages.map(&:action)).to eq(%i[first surplus exclusion exclusion])
    expect(result.stages[0].elected).to eq(%w[chocolate])
    # Chocolate's 6 surplus votes move on at half value.
    expect(result.stages[1].tallies).to include("chocolate" => 6, "strawberry" => 5, "burger" => 3)
    expect(result.stages[2].excluded).to eq(%w[pear])
    expect(result.stages[2].elected).to eq(%w[orange])
    expect(result.stages[3].elected).to eq(%w[strawberry])
    expect(result.exhausted).to eq(3)
  end

  it "counts a ballot of weight 3 exactly like three ballots of weight 1" do
    unweighted = food.flat_map { |b| Array.new(b.weight) { ballot(1, *b.ranking) } }

    weighted = count(dishes, food)
    split = count(dishes, unweighted)

    expect(split.elected).to eq(weighted.elected)
    expect(split.stages.map(&:tallies)).to eq(weighted.stages.map(&:tallies))
  end

  it "lets weight decide: one trust level 4 vote outweighs three trust level 1 votes" do
    result =
      count(%w[a b], [ballot(4, "a"), ballot(1, "b"), ballot(1, "b"), ballot(1, "b")], seats: 1)
    expect(result.elected).to eq(%w[a])
  end

  it "never counts a lower choice against a higher one" do
    # Adding a second choice to the ballots that elect "a" can't stop "a".
    plain = count(%w[a b c], [ballot(3, "a"), ballot(2, "b"), ballot(2, "c")], seats: 1)
    with_seconds = count(%w[a b c], [ballot(3, "a", "b"), ballot(2, "b"), ballot(2, "c")], seats: 1)

    expect(plain.elected).to eq(%w[a])
    expect(with_seconds.elected).to eq(%w[a])
  end

  it "ignores names that aren't running, repeats, and empty or weightless ballots" do
    result =
      count(
        %w[a b c d],
        [
          ballot(2, "ghost", "a", "a", "b"),
          ballot(0, "c"),
          ballot(3),
          ballot(1, "d"),
          ballot(1, "c"),
        ],
        seats: 1,
      )

    expect(result.ballots).to eq(3)
    expect(result.total).to eq(4)
    expect(result.elected).to eq(%w[a])
  end

  it "elects everyone unopposed when there are no more candidates than seats" do
    result = count(%w[a b], [ballot(2, "a")])

    expect(result.outcome).to eq(:unopposed)
    expect(result.elected).to contain_exactly("a", "b")
  end

  it "elects nobody in a contested election nobody voted in" do
    result = count(%w[a b c d], [])

    expect(result.outcome).to eq(:no_votes)
    expect(result.elected).to be_empty
  end

  describe "ties" do
    it "excludes whoever did worse at the earliest stage they differed" do
      # After a's surplus moves, b and c are level, but c had fewer first
      # preferences, so c goes.
      result =
        count(
          %w[a b c d],
          [ballot(7, "a", "c"), ballot(3, "b"), ballot(2, "c"), ballot(4, "d")],
          seats: 2,
        )

      exclusion = result.stages.find { |s| s.action == :exclusion }
      expect(exclusion.excluded).to eq(%w[c])
      expect(exclusion.ties.sole).to have_attributes(
        purpose: :exclusion,
        method: :earlier_stage,
        among: %w[b c],
        chosen: "c",
        decided_at: 1,
      )
    end

    it "draws lots when the candidates were level at every stage" do
      ballots = %w[a b c d].map { |id| ballot(1, id) }

      results = (1..20).map { |seed| count(%w[a b c d], ballots, seed: seed) }
      exclusions = results.map { |r| r.stages.find { |s| s.action == :exclusion } }
      excluded = exclusions.map { |stage| stage.excluded.sole }

      expect(exclusions.first.ties.find { |t| t.purpose == :exclusion }.method).to eq(:lot)
      # Same seed, same draw.
      expect(count(%w[a b c d], ballots, seed: 7).elected).to eq(
        count(%w[a b c d], ballots, seed: 7).elected,
      )
      # And the draw isn't always the same person.
      expect(excluded.uniq.size).to be > 1
    end

    it "names only those still level after the earlier stages as the lot's field" do
      # After a's surplus moves, b, c and d all have 2. At the first stage d
      # had 2 and b and c had 1 each, so d is safe; b and c were level at
      # every stage, so a lot decides between those two only.
      result =
        count(
          %w[a b c d e],
          [
            ballot(4, "a", "b"),
            ballot(4, "a", "c"),
            ballot(1, "b"),
            ballot(1, "c"),
            ballot(2, "d"),
            ballot(3, "e"),
          ],
          seats: 2,
        )

      tie = result.stages.find { |s| s.action == :exclusion }.ties.sole
      expect(tie).to have_attributes(
        purpose: :exclusion,
        method: :lot,
        among: %w[b c],
        decided_at: nil,
      )
      expect(tie.chosen).to eq("b").or eq("c")
    end
  end

  describe "candidates with no votes" do
    it "go out together, without drawing lots between them" do
      result = count(%w[a b c d e], [ballot(3, "a"), ballot(2, "b"), ballot(1, "c")], seats: 2)

      zeros = result.stages.find { |s| s.excluded.size > 1 }
      expect(zeros.excluded).to contain_exactly("d", "e")
      expect(zeros.ties).to be_empty
      expect(result.elected).to eq(%w[a b])
      expect(result.stages.flat_map(&:ties).map(&:method)).not_to include(:lot)
    end

    it "still go one at a time by lot when too few would be left for the seats" do
      result = count(%w[a b c], [ballot(5, "a")], seats: 2)

      exclusion = result.stages.find { |s| s.action == :exclusion }
      expect(exclusion.excluded.size).to eq(1)
      expect(exclusion.ties.sole).to have_attributes(purpose: :exclusion, method: :lot)
      expect(result.elected.size).to eq(2)
    end
  end

  it "puts people elected together on equal votes in order, and records how" do
    result = count(%w[a b c], [ballot(3, "a"), ballot(3, "b"), ballot(1, "c")], seats: 2)

    first = result.stages.first
    expect(first.elected).to contain_exactly("a", "b")
    expect(first.ties.sole).to have_attributes(purpose: :order, method: :lot, among: %w[a b])
    expect(result.elected.first).to eq(first.ties.sole.chosen)
  end

  # Whatever the ballots, a count must add up: every vote is with a
  # candidate or exhausted at every stage, and the right number are elected.
  it "keeps its books balanced on random elections" do
    rng = Random.new(42)
    300.times do
      ids = (1..rng.rand(1..7)).map { |i| "c#{i}" }
      seats = rng.rand(1..4)
      ballots =
        Array.new(rng.rand(0..25)) do
          ballot(rng.rand(0..4), *ids.shuffle(random: rng).first(rng.rand(0..ids.size)))
        end
      result = count(ids, ballots, seats: seats, seed: rng.rand(1000))

      result.stages.each do |stage|
        expect(stage.tallies.values.sum + stage.exhausted).to eq(result.total)
      end
      expect(result.elected).to eq(result.elected.uniq)
      expect(result.elected - ids).to be_empty
      excluded = result.stages.flat_map(&:excluded)
      expect(result.elected & excluded).to be_empty
      expected = result.outcome == :no_votes ? 0 : [seats, ids.size].min
      expect(result.elected.size).to eq(expected)
    end
  end

  it "recounts as if a candidate never ran (a countback)" do
    result = count(dishes, food, excluded: %w[chocolate])

    expect(result.elected).not_to include("chocolate")
    expect(result.stages.first.tallies.keys).not_to include("chocolate")
    expect(result.elected.size).to eq(3)
  end
end
