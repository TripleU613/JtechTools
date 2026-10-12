# frozen_string_literal: true

module DiscourseModElections
  # The elections page: what's happening, who's running, your ballot, the
  # results. Running and voting only work from the member's own browser
  # session: an API key or an admin impersonating someone can't nominate or
  # vote as them.
  class ElectionsController < ::ApplicationController
    requires_plugin "jtech-tools"

    before_action :ensure_enabled
    before_action :ensure_logged_in, except: %i[page show]
    before_action :ensure_own_session, except: %i[page show]
    before_action :limit_writes, except: %i[page show]
    before_action :find_election, except: %i[page show]

    rescue_from DiscourseModElections::Error do |e|
      render_json_error(
        I18n.t("mod_elections.errors.#{e.reason}", **e.details),
        status: e.reason == :not_found ? 404 : 422,
        extras: {
          reason: e.reason,
        },
      )
    end

    # Server-rendered shell so a hard load or a link to /elections boots
    # Ember.
    def page
      render "default/empty"
    end

    def show
      election =
        if params[:id].present?
          Election.where.not(status: :scheduled).find_by(id: params[:id])
        else
          Presenter.default_election
        end
      raise Discourse::NotFound if params[:id].present? && election.nil?
      render_json_dump(Presenter.page(election, current_user, guardian))
    end

    def run
      Nominations.run!(current_user, @election, params[:statement])
      render_page
    end

    def update_candidacy
      Nominations.update_statement!(current_user, @election, params[:statement])
      render_page
    end

    def withdraw
      Nominations.withdraw!(current_user, @election)
      render_page
    end

    def vote
      # Only a flat list of ids: anything else is treated as an empty ballot.
      ranking = params.permit(ranking: [])[:ranking]
      Voting.cast!(current_user, @election, ranking, ip_address: request.remote_ip)
      render_page
    end

    def clear_ballot
      Voting.clear!(current_user, @election)
      render_page
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless DiscourseModElections.enabled?
    end

    def ensure_own_session
      if is_api? || is_user_api? || current_user&.is_impersonating
        raise Discourse::InvalidAccess.new(I18n.t("mod_elections.errors.own_session_only"))
      end
    end

    # Generous for a person reordering a ballot a few times, tight for a
    # script. Over the limit, core answers 429 with when to try again.
    def limit_writes
      RateLimiter.new(current_user, "mod-elections-write", 30, 1.minute).performed!
      RateLimiter.new(current_user, "mod-elections-write-hourly", 200, 1.hour).performed!
    end

    def find_election
      @election = Election.where.not(status: :scheduled).find_by(id: params[:id])
      raise Discourse::NotFound if @election.nil?
    end

    def render_page
      render_json_dump(Presenter.page(@election.reload, current_user, guardian))
    end
  end
end
