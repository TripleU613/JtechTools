# frozen_string_literal: true

module DiscourseModElections
  # The Mod elections admin tab. Admins only: moderators are candidates, so
  # they get none of this, not even the turnout.
  class AdminController < ::Admin::AdminController
    requires_plugin "jtech-tools"

    # Reading works while the module is off, so the tab can say so and show
    # what happened; changing anything waits until it's back on.
    READ_ONLY = %i[index show ip_report seats countback].freeze
    before_action :ensure_enabled, except: READ_ONLY
    before_action :find_election, except: %i[index create seats countback fill vacate]

    rescue_from DiscourseModElections::Error do |e|
      render_json_error(
        I18n.t("mod_elections.errors.#{e.reason}", **e.details),
        status: e.reason == :not_found ? 404 : 422,
        extras: {
          reason: e.reason,
        },
      )
    end

    def index
      render_json_dump(Presenter.admin_index)
    end

    def show
      render_json_dump(Presenter.admin_election(@election))
    end

    def create
      election =
        Lifecycle.create!(
          current_user,
          seats: params[:seats].presence&.to_i || SiteSetting.mod_elections_seats,
          nominations_open_at: parse_time(:nominations_open_at),
          voting_open_at: parse_time(:voting_open_at),
          voting_close_at: parse_time(:voting_close_at),
        )
      render_json_dump(Presenter.admin_election(election))
    end

    def end_phase
      Lifecycle.end_phase!(@election, current_user)
      render_json_dump(Presenter.admin_election(@election.reload))
    end

    def cancel
      Publisher.cancel!(@election, current_user)
      render_json_dump(Presenter.admin_election(@election.reload))
    end

    def disqualify
      Nominations.disqualify!(find_candidate, params[:reason], current_user)
      render_json_dump(Presenter.admin_election(@election.reload))
    end

    def reinstate
      Nominations.reinstate!(find_candidate, current_user)
      render_json_dump(Presenter.admin_election(@election.reload))
    end

    # Only once voting has closed: during Vote Week it would say who has
    # voted. Publishing clears the addresses.
    def ip_report
      raise Error.new(:finished) unless @election.unfinished?
      raise Error.new(:not_closed) unless @election.closed?
      render_json_dump(ip_report: Presenter.ip_report(@election))
    end

    def void_ballot
      Voting.void!(find_ballot, params[:reason], current_user)
      render_json_dump(ip_report: Presenter.ip_report(@election))
    end

    def restore_ballot
      Voting.restore!(find_ballot, current_user)
      render_json_dump(ip_report: Presenter.ip_report(@election))
    end

    def preview
      preview = Publisher.preview(@election)
      render_json_dump(
        result: Presenter.result_json(preview[:result]),
        plan: Presenter.plan(preview[:plan]),
      )
    end

    def publish
      Publisher.publish!(@election, current_user)
      render_json_dump(Presenter.admin_election(@election.reload))
    end

    # ── Seats between elections ───────────────────────────────────────────

    def seats
      election = Countback.current_election
      raise Discourse::NotFound if election.nil?
      render_json_dump(Presenter.seats_json(election))
    end

    def vacate
      election = Countback.current_election
      raise Discourse::NotFound if election.nil?
      candidate = election.candidates.find_by(id: params[:candidate_id])
      raise Discourse::NotFound if candidate.nil?
      Seats.vacate!(candidate, params[:reason].to_s, current_user)
      render_json_dump(Presenter.seats_json(election))
    end

    def countback
      election = Countback.current_election
      raise Discourse::NotFound if election.nil?
      candidate = Countback.replacement(election)
      render_json_dump(replacement: candidate && Presenter.basic_user(candidate.user))
    end

    def fill
      election = Countback.current_election
      raise Discourse::NotFound if election.nil?
      Countback.fill!(election, current_user)
      render_json_dump(Presenter.seats_json(election))
    end

    private

    def ensure_enabled
      raise DiscourseModElections::Error.new(:module_off) unless DiscourseModElections.enabled?
    end

    def find_election
      @election = Election.find_by(id: params[:id])
      raise Discourse::NotFound if @election.nil?
    end

    def find_candidate
      @election.candidates.find_by(id: params[:candidate_id]) || raise(Discourse::NotFound)
    end

    def find_ballot
      @election.ballots.find_by(id: params[:ballot_id]) || raise(Discourse::NotFound)
    end

    def parse_time(key)
      Time.zone.parse(params.require(key).to_s)
    rescue ArgumentError
      raise DiscourseModElections::Error.new(:invalid_dates)
    end
  end
end
