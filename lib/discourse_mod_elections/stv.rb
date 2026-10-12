# frozen_string_literal: true

module DiscourseModElections
  # Counts a multi-seat election by single transferable vote, the way
  # Scottish council elections do (Droop quota, weighted inclusive Gregory
  # surplus transfers), except that a ballot starts at its voter's weight
  # instead of 1.
  #
  # Pure Ruby: candidate ids, ballots and a seed in, every stage out. Values
  # are Rationals, so a transfer never rounds and a tie is an exact tie.
  class Stv
    Ballot = Struct.new(:weight, :ranking)

    # action is :first, :unopposed, :surplus (candidate's surplus moved on)
    # or :exclusion (everyone in excluded is out). ties lists every tie the
    # stage had to settle, and how.
    Stage =
      Struct.new(
        :number,
        :action,
        :candidate,
        :excluded,
        :tallies,
        :exhausted,
        :elected,
        :ties,
        keyword_init: true,
      )

    # purpose: :exclusion (who goes out), :surplus (whose surplus moves
    # first) or :order (who is listed, and so counted back, first among
    # people elected on equal votes). decided_at: the stage whose votes
    # settled it, when it wasn't settled by lot.
    Tie = Struct.new(:purpose, :method, :among, :chosen, :decided_at, keyword_init: true)

    Result =
      Struct.new(
        :seats,
        :quota,
        :total,
        :ballots,
        :elected,
        :stages,
        :exhausted,
        :seed,
        :outcome,
        keyword_init: true,
      )

    Paper = Struct.new(:ranking, :value)

    def self.count(**kwargs)
      new(**kwargs).count
    end

    # candidates: ids still in the race. ballots: Ballot-likes (weight,
    # ranking of candidate ids, best first). excluded: ids to count as if they
    # never ran (a countback after someone leaves their seat).
    def initialize(candidates:, ballots:, seats:, seed:, excluded: [])
      @candidates = candidates.uniq - excluded
      @seats = seats
      @seed = seed
      @rng = Random.new(seed)
      @papers =
        ballots.filter_map do |ballot|
          ranking = ballot.ranking.uniq & @candidates
          next if ranking.empty? || ballot.weight.to_i <= 0
          Paper.new(ranking, Rational(ballot.weight.to_i))
        end
      @state = @candidates.to_h { |id| [id, :continuing] }
      @piles = @candidates.to_h { |id| [id, []] }
      @settled = {}
      @elected = []
      @stages = []
      @pending_ties = []
      @exhausted = Rational(0)
    end

    def count
      @total = @papers.sum(Rational(0), &:value)
      @quota = (@total / (@seats + 1)).floor + 1
      @papers.each { |paper| place(paper) }

      if @candidates.size <= @seats
        record(:unopposed)
        # Everyone is elected and nobody is left to count back to, so the
        # order is only for reading: most votes first, no lots drawn.
        elect(*continuing.sort_by { |id| [-votes(id), id] })
        return result(:unopposed)
      end

      record(:first)
      return result(:no_votes) if @total.zero?

      pending = []
      loop do
        pending.concat(elect_reaching_quota)
        break if @elected.size == @seats

        if @elected.size + continuing.size <= @seats
          elect(*ordered(continuing))
          break
        end

        pending.reject! { |id| surplus(id).zero? }
        if pending.any?
          id =
            pick(pending, highest: true, purpose: :surplus, into: @pending_ties) { |c| surplus(c) }
          pending.delete(id)
          transfer_surplus(id)
          record(:surplus, candidate: id)
        else
          exclude_lowest
        end
      end

      result(:counted)
    end

    private

    def continuing
      @candidates.select { |id| @state[id] == :continuing }
    end

    def votes(id)
      @settled[id] || @piles[id].sum(Rational(0), &:value)
    end

    def surplus(id)
      [votes(id) - @quota, 0].max
    end

    # The paper goes to its highest-ranked candidate still in the race, or is
    # exhausted when it names none.
    def place(paper)
      holder = paper.ranking.find { |id| @state[id] == :continuing }
      if holder
        @piles[holder] << paper
      else
        @exhausted += paper.value
      end
    end

    def elect_reaching_quota
      reached = ordered(continuing.select { |id| votes(id) >= @quota })
      elect(*reached)
      reached
    end

    def elect(*ids)
      ids.each do |id|
        @state[id] = :elected
        @elected << id
        @stages.last.elected << id
      end
    end

    # Candidates with no votes at all hold no papers, so taking them out
    # together changes nothing for anyone else and needs no lot between
    # them, as long as enough candidates stay in for the seats left.
    def exclude_lowest
      zeros = continuing.select { |id| votes(id).zero? }
      if zeros.size > 1 && continuing.size - zeros.size >= @seats - @elected.size
        zeros.each { |id| exclude(id) }
        record(:exclusion, excluded: zeros)
      else
        id =
          pick(continuing, highest: false, purpose: :exclusion, into: @pending_ties) do |c|
            votes(c)
          end
        exclude(id)
        record(:exclusion, excluded: [id])
      end
    end

    # Every paper the elected candidate holds moves on at a reduced value,
    # so that together they carry exactly the surplus.
    def transfer_surplus(id)
      held = votes(id)
      factor = surplus(id) / held
      papers = @piles[id]
      @piles[id] = []
      @settled[id] = @quota
      papers.each do |paper|
        paper.value *= factor
        place(paper)
      end
    end

    def exclude(id)
      @state[id] = :excluded
      papers = @piles[id]
      @piles[id] = []
      @settled[id] = Rational(0)
      papers.each { |paper| place(paper) }
    end

    # Most votes first. People elected at the same stage on equal votes are
    # put in order the same way any other tie is settled, and the tie is
    # recorded on that stage: a countback gives a seat to the first newly
    # elected candidate, so the order can matter.
    def ordered(ids)
      rest = ids.dup
      order = []
      until rest.empty?
        id = pick(rest, highest: true, purpose: :order, into: @stages.last.ties) { |c| votes(c) }
        order << id
        rest.delete(id)
      end
      order
    end

    # The candidate with the highest (or lowest) value. A tie goes to the
    # earliest stage where the tied candidates had different votes, then to
    # lot; either way it's added to `into`.
    def pick(ids, highest:, purpose:, into:, &value)
      best = highest ? ids.map(&value).max : ids.map(&value).min
      tied = ids.select { |id| value.call(id) == best }
      return tied.first if tied.size == 1

      remaining = tied
      decided_at = nil
      @stages.each do |stage|
        values = remaining.map { |id| stage.tallies[id] }
        next if values.uniq.size == 1
        target = highest ? values.max : values.min
        remaining = remaining.select { |id| stage.tallies[id] == target }
        decided_at = stage.number
        break if remaining.size == 1
      end

      chosen =
        if remaining.size == 1
          remaining.first
        else
          decided_at = nil
          remaining.sort[@rng.rand(remaining.size)]
        end
      into << Tie.new(
        purpose: purpose,
        method: decided_at ? :earlier_stage : :lot,
        among: tied.sort,
        chosen: chosen,
        decided_at: decided_at,
      )
      chosen
    end

    def record(action, candidate: nil, excluded: [])
      @stages << Stage.new(
        number: @stages.size + 1,
        action: action,
        candidate: candidate,
        excluded: excluded,
        tallies: @candidates.to_h { |id| [id, votes(id)] },
        exhausted: @exhausted,
        elected: [],
        ties: @pending_ties,
      )
      @pending_ties = []
    end

    def result(outcome)
      Result.new(
        seats: @seats,
        quota: @quota,
        total: @total,
        ballots: @papers.size,
        elected: @elected,
        stages: @stages,
        exhausted: @exhausted,
        seed: @seed,
        outcome: outcome,
      )
    end
  end
end
