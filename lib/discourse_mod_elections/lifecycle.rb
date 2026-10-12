# frozen_string_literal: true

module DiscourseModElections
  # Moves elections along the calendar. Jobs::ModElectionsTick runs this
  # every minute; every step is safe to repeat.
  module Lifecycle
    def self.tick(now = Time.zone.now)
      return unless DiscourseModElections.enabled?
      schedule!(now)
      Election.unfinished.order(:id).each { |election| advance!(election, now) }
    end

    # Creates the election the calendar says should be running, unless
    # there's already one that month (a cancelled one counts, so cancelling
    # sticks, even if the time zone setting changes) or another is still
    # unfinished.
    def self.schedule!(now)
      dates = Schedule.slot_at(now)
      return if dates.nil?
      # Too late for nominations (say the module was switched on mid-month):
      # starting now would skip straight to Vote Week. Wait for the next one.
      return if now >= dates[:voting_open_at]
      # A day's slack each side: an election that opened at midnight in the
      # old zone can fall on the last day of the previous month in the new.
      opens = dates[:nominations_open_at]
      month = (opens.beginning_of_month - 1.day)..(opens.end_of_month + 1.day)
      return if Election.where(nominations_open_at: month).exists?
      return if Election.unfinished.exists?
      Election.create!(dates.merge(seats: SiteSetting.mod_elections_seats))
    end

    # Moves the election to wherever the clock says it should be. The
    # status changes under the election's lock; what follows from them
    # (topic posts, notifications) runs after it, so a failed post can't
    # roll a phase back and leave the election stuck.
    def self.advance!(election, now = Time.zone.now)
      steps = []
      incumbents = []
      election.with_lock do
        if election.scheduled? && now >= election.nominations_open_at
          election.update!(status: :nominating)
          Roll.snapshot!(election, now: now)
          incumbents = Nominations.add_incumbents!(election)
          steps << :nominations_open
        end
        if election.nominating? && now >= election.voting_open_at
          election.update!(status: :voting)
          steps << :voting_open
        end
        if election.voting? && remind_now?(election, now)
          election.update!(reminder_sent_at: now)
          steps << :reminder
        end
        if election.voting? && now >= election.voting_close_at
          # Under 2**53 so it survives a round trip through JavaScript
          # exactly: the seed is published so anyone can check a drawn lot.
          election.update!(status: :closed, seed: SecureRandom.random_number(2**52))
          steps << :closed
        end
      end

      State.changed! if (steps - [:reminder]).any?
      steps.each { |step| follow_up(election, step, incumbents: incumbents) }
      election
    end

    # A day before Vote Week ends, but never in its first day: a short Vote
    # Week would otherwise send "it's open" and "it ends tomorrow" together.
    def self.remind_now?(election, now)
      return false if election.reminder_sent_at.present? || now >= election.voting_close_at
      now >= [election.voting_close_at - 1.day, election.voting_open_at + 1.day].max
    end

    def self.follow_up(election, step, incumbents: [])
      notify_voters = SiteSetting.mod_elections_notify_voters
      case step
      when :nominations_open
        Notifier.notify(incumbents, election, "on_ballot") if incumbents.any?
        Announcer.nominations_open(election)
      when :voting_open
        Announcer.voting_open(election)
        Notifier.enqueue_voters(election, "voting_open") if notify_voters
      when :reminder
        Notifier.enqueue_voters(election, "reminder") if notify_voters
      when :closed
        Notifier.notify(User.real.where(admin: true).pluck(:id), election, "closed")
        Disteleplus.closed(election)
      end
    rescue StandardError => e
      Rails.logger.warn("#{DiscourseModElections::LOG_TAG} #{step} follow-up failed: #{e.message}")
    end

    # An admin ends the current phase early.
    def self.end_phase!(election, actor, now = Time.zone.now)
      election.with_lock do
        if election.scheduled?
          gap = election.nominations_open_at - now
          election.update!(
            nominations_open_at: now,
            voting_open_at: election.voting_open_at - gap,
            voting_close_at: election.voting_close_at - gap,
          )
        elsif election.nominating?
          raise Error.new(:too_early) if now <= election.nominations_open_at
          election.update!(
            voting_open_at: now,
            voting_close_at: [election.voting_close_at, now + 1.minute].max,
          )
        elsif election.voting?
          election.update!(voting_close_at: now)
        else
          raise Error.new(:finished)
        end
      end
      StaffActionLogger.new(actor).log_custom(
        "mod_election_end_phase",
        election_id: election.id,
        status: election.status,
      )
      advance!(election.reload, now)
    end

    # An election an admin starts by hand, for dates off the calendar.
    def self.create!(actor, seats:, nominations_open_at:, voting_open_at:, voting_close_at:)
      raise Error.new(:election_in_progress) if Election.unfinished.exists?
      unless nominations_open_at && voting_open_at && voting_close_at &&
               nominations_open_at < voting_open_at && voting_open_at < voting_close_at
        raise Error.new(:invalid_dates)
      end
      election =
        Election.new(
          seats: seats,
          nominations_open_at: nominations_open_at,
          voting_open_at: voting_open_at,
          voting_close_at: voting_close_at,
          created_by: actor,
        )
      raise Error.new(:invalid_dates) unless election.valid?
      election.save!
      StaffActionLogger.new(actor).log_custom("mod_election_create", election_id: election.id)
      advance!(election)
    end
  end
end
