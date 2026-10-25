# frozen_string_literal: true

module DiscourseModElections
  # The results post in the election's topic: the winners, then the whole
  # count as charts anyone can check, from the stored result alone, like
  # the elections page. Never who ranked whom: only what the published
  # stages already say.
  #
  # The charts are text (bars of block characters in Markdown tables), so
  # they read the same on the full site, in Dumbcourse and in email.
  module ResultsPost
    # Bumped when the post changes, so every published election's post is
    # written again (backfill!).
    VERSION = 1
    STORE = "jtech-mod-elections"
    DONE_KEY = "results_post_v#{VERSION}"
    BAR_CELLS = 16
    EIGHTHS = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"].freeze

    # Writes the results post for an election just published.
    def self.post!(election)
      write!(election)
    end

    # Published elections whose results post predates this version get
    # theirs written again: the post that carries their results link is
    # edited in place (without bumping the topic), or one is added if
    # there's none. The tick runs it, so it waits while the module is off.
    def self.backfill!
      done = Array(PluginStore.get(STORE, DONE_KEY))
      Election
        .published
        .where.not(topic_id: nil)
        .where.not(id: done)
        .order(:id)
        .each { |election| write!(election) }
    end

    def self.write!(election)
      if election.result.present? && Topic.exists?(id: election.topic_id)
        raw = raw(election)
        post = existing_post(election)
        if post
          post.revise(
            Discourse.system_user,
            { raw: raw },
            skip_validations: true,
            bypass_bump: true,
          )
        else
          Announcer.reply(election, raw)
        end
      end
      done!(election)
    rescue StandardError => e
      Rails.logger.warn(
        "#{DiscourseModElections::LOG_TAG} results post for election #{election.id} failed: #{e.message}",
      )
    end

    # The system's post with this election's results link. The closing
    # bracket keeps election 5 from matching election 50.
    def self.existing_post(election)
      Post
        .where(topic_id: election.topic_id, user_id: Discourse::SYSTEM_USER_ID)
        .where("raw LIKE ?", "%/elections?id=#{election.id})%")
        .order(:post_number)
        .last
    end

    def self.done!(election)
      done = Array(PluginStore.get(STORE, DONE_KEY))
      PluginStore.set(STORE, DONE_KEY, (done | [election.id]).sort)
    end

    def self.raw(election)
      Builder.new(election).raw
    end

    class Builder
      def initialize(election)
        @election = election
        @result = election.result || {}
        @stages = Array(@result["stages"])
        @elected = Array(@result["elected"])
        @total = @result["total"].to_f
        @quota = @result["quota"].to_f
        user_ids = Array(@result["candidates"]).to_h { |c| [c["id"], c["user_id"]] }
        usernames = User.where(id: user_ids.values.compact).pluck(:id, :username).to_h
        @names = user_ids.transform_values { |user_id| usernames[user_id] }
        @candidate_ids = user_ids.keys
      end

      def raw
        parts = [winners]
        parts << count if @result["ballots"].to_i > 0 && @total > 0
        parts << t("link", url: "#{Announcer.page_url}?id=#{@election.id}")
        parts.join("\n\n")
      end

      private

      def t(key, **args)
        I18n.t("mod_elections.topic.count.#{key}", **args)
      end

      def winners
        lines = @elected.map { |id| "- #{link(id)}" }
        lines = ["- #{I18n.t("mod_elections.topic.nobody")}"] if lines.empty?
        key = @result["ballots"].to_i > 0 ? "winners" : "winners_unopposed"
        "#{t(key)}\n#{lines.join("\n")}"
      end

      def count
        body = [
          "## #{t("title")}",
          summary,
          "### #{t("first_title")}",
          t("first_intro"),
          first_choices,
          "### #{t("stages_title")}",
          stage_story,
          "### #{t("final_title")}",
          t("final_intro"),
          final_count,
          leftovers,
          ties,
          every_stage,
        ].compact
        "[wrap=mod-election-count]\n#{body.join("\n\n")}\n[/wrap]"
      end

      def summary
        t(
          "summary",
          seats: @result["seats"].to_i,
          ballots: @result["ballots"].to_i,
          total: votes(@total),
          quota: votes(@quota),
          quota_share: percent(@quota),
        )
      end

      # Everyone's first-choice votes, most first.
      def first_choices
        tallies = @stages.first&.dig("tallies") || {}
        rows = @candidate_ids.map { |id| [id, tallies[id.to_s].to_f] }.sort_by { |id, v| [-v, id] }
        chart(rows)
      end

      # Where everyone finished: winners in the order they were elected, at
      # the votes that elected them; everyone else at their last votes before
      # going out, latest out first.
      def final_count
        elected_at = {}
        out_at = {}
        @stages.each do |stage|
          Array(stage["elected"]).each { |id| elected_at[id] ||= stage["number"] }
          Array(stage["excluded"]).each { |id| out_at[id] ||= stage["number"] }
        end
        rows =
          @elected.map do |id|
            [id, tally_at(id, elected_at[id]), t("elected_at", stage: elected_at[id])]
          end
        others = @candidate_ids - @elected
        others =
          others.sort_by do |id|
            [-(out_at[id] || @stages.size + 1), -tally_at(id, last_stage_for(id, out_at)), id]
          end
        others.each do |id|
          stage = out_at[id]
          note = stage ? t("out_at", stage: stage) : t("not_elected")
          rows << [id, tally_at(id, last_stage_for(id, out_at)), note]
        end
        chart(rows, notes: true)
      end

      # The stage whose votes someone finished on: the one before they went
      # out (by then their votes have moved on), else the last.
      def last_stage_for(id, out_at)
        stage = out_at[id]
        stage ? [stage - 1, 1].max : @stages.size
      end

      def tally_at(id, number)
        stage = @stages.find { |s| s["number"] == number } || @stages.last
        stage&.dig("tallies", id.to_s).to_f
      end

      # A table: candidate, votes, share of all votes and a bar, longest for
      # the most votes in the table.
      def chart(rows, notes: false)
        top = rows.map { |row| row[1] }.max.to_f
        header = [t("candidate"), t("votes"), t("share"), ""]
        header << t("outcome") if notes
        align = %w[--- ---: ---: ---]
        align << "---" if notes
        lines = [table_row(header), table_row(align)]
        rows.each do |id, value, note|
          cells = [link(id), votes(value), percent(value), bar(value, top)]
          cells << note if notes
          lines << table_row(cells)
        end
        lines.join("\n")
      end

      def table_row(cells)
        "| #{cells.join(" | ")} |"
      end

      # Block characters to an eighth of a cell, so close results look close.
      def bar(value, top)
        return "" if top <= 0 || value <= 0
        eighths = (value / top * BAR_CELLS * 8).round
        eighths = 1 if eighths.zero?
        ("█" * (eighths / 8)) + EIGHTHS[eighths % 8]
      end

      # What each stage did, in words.
      def stage_story
        @stages
          .map do |stage|
            lines = ["#{stage["number"]}. **#{stage_label(stage)}**"]
            lines << stage_detail(stage)
            elected = Array(stage["elected"])
            if elected.any?
              names =
                elected.map do |id|
                  t(
                    "elected_with",
                    name: link(id),
                    votes: votes(stage.dig("tallies", id.to_s).to_f),
                  )
                end
              lines << t("elected", names: names.join(", "))
            end
            lines.compact.join(" ")
          end
          .join("\n")
      end

      def stage_label(stage)
        case stage["action"]
        when "surplus"
          t("stage_surplus", name: name(stage["candidate"]))
        when "exclusion"
          t(
            "stage_exclusion",
            count: Array(stage["excluded"]).size,
            names: names(stage["excluded"]),
          )
        when "unopposed"
          t("stage_unopposed")
        else
          t("stage_first")
        end
      end

      def stage_detail(stage)
        case stage["action"]
        when "surplus"
          t("detail_surplus")
        when "exclusion"
          t("detail_exclusion", count: Array(stage["excluded"]).size)
        when "unopposed"
          t("detail_unopposed")
        end
      end

      def leftovers
        exhausted = @result["exhausted"].to_f
        return if exhausted <= 0
        t("exhausted", votes: votes(exhausted), share: percent(exhausted))
      end

      def ties
        lines =
          @stages.flat_map do |stage|
            Array(stage["ties"]).map do |tie|
              t(
                "ties.#{tie["purpose"]}_#{tie["method"]}",
                stage: stage["number"],
                names: names(tie["among"]),
                chosen: name(tie["chosen"]),
                decided_at: tie["decided_at"],
                seed: @result["seed"],
              )
            end
          end
        return if lines.empty?
        "### #{t("ties_title")}\n#{lines.map { |line| "- #{line}" }.join("\n")}"
      end

      # The whole count in numbers, folded away: every candidate at every
      # stage, and the votes with no more choices.
      def every_stage
        numbers = @stages.map { |s| s["number"] }
        out_at = {}
        @stages.each { |s| Array(s["excluded"]).each { |id| out_at[id] ||= s["number"] } }
        lines = [
          table_row([t("candidate")] + numbers.map(&:to_s)),
          table_row(["---"] + numbers.map { "---:" }),
        ]
        (@elected + (@candidate_ids - @elected)).each do |id|
          cells =
            @stages.map do |s|
              out = out_at[id] && out_at[id] <= s["number"]
              out ? "—" : votes(s.dig("tallies", id.to_s).to_f)
            end
          lines << table_row([link(id)] + cells)
        end
        lines << table_row([t("no_more_choices")] + @stages.map { |s| votes(s["exhausted"].to_f) })
        "[details=\"#{t("every_stage")}\"]\n#{lines.join("\n")}\n[/details]"
      end

      def name(id)
        @names[id].presence || I18n.t("mod_elections.topic.deleted_user")
      end

      def names(ids)
        Array(ids).map { |id| name(id) }.join(", ")
      end

      def link(id)
        Announcer.user_link_for(@names[id])
      end

      def votes(value)
        ActiveSupport::NumberHelper.number_to_rounded(
          value,
          precision: 2,
          strip_insignificant_zeros: true,
        )
      end

      def percent(value)
        return "—" if @total <= 0
        share =
          ActiveSupport::NumberHelper.number_to_rounded(
            value / @total * 100,
            precision: 1,
            strip_insignificant_zeros: true,
          )
        "#{share}%"
      end
    end
  end
end
