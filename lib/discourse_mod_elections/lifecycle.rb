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
      blocking = nil
      creating do
        next if Election.where(nominations_open_at: month).exists?
        blocking = Election.unfinished.order(:id).first
        next if blocking
        Election.create!(dates.merge(seats: SiteSetting.mod_elections_seats))
      end
      # Once Vote Week would have opened the schedule stops trying, so an
      # election nobody published or cancelled would skip this one quietly.
      # Admins hear about it (once per election in the way).
      warn_blocked(blocking) if blocking
    end

    def self.warn_blocked(election)
      Notifier.notify(User.real.where(admin: true).pluck(:id), election, "schedule_blocked")
    rescue StandardError => e
      Rails.logger.warn(
        "#{DiscourseModElections::LOG_TAG} schedule_blocked notice failed: #{e.message}",
      )
    end

    # One election at a time: the schedule and an admin starting one by
    # hand check for an unfinished election and create one under the same
    # mutex, so they can't both get through.
    def self.creating(&block)
      DistributedMutex.synchronize("jtech-mod-elections-create", validity: 30.seconds, &block)
    end

    # Moves the election to wherever the clock says it should be. The
    # status changes under the election's lock; what follows from them
    # (topic posts, notifications) runs after it, so a failed post can't
    # roll a phase back and leave the election stuck.
    def self.advance!(election, now = Time.zone.now, extend_nominations: true)
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
          steps << close_nominations!(election, now, extend: extend_nominations)
        end
        if election.voting? && remind_now?(election, now)
          election.update!(reminder_sent_at: now)
          steps << :reminder
        end
        if election.voting? && now >= election.voting_close_at
          election.update!(status: :closed, seed: draw_seed)
          steps << :closed
        end
      end

      State.changed! if (steps - [:reminder]).any?
      steps.each { |step| follow_up(election, step, incumbents: incumbents) }
      election
    end

    # With more candidates than seats, Vote Week opens. With no more, the
    # count elects them all whatever the ballots say: nominations stay open
    # a few days longer, once, for others to run, and if it's still so
    # there's no Vote Week. The admin publishes them as elected unopposed.
    def self.close_nominations!(election, now, extend:)
      if !election.uncontested?
        election.update!(status: :voting)
        :voting_open
      elsif extend && extend_nominations!(election, now)
        :nominations_extended
      else
        election.update!(
          status: :closed,
          voting_close_at: election.voting_open_at,
          vote_skipped_at: now,
          seed: draw_seed,
        )
        :vote_skipped
      end
    end

    # Whole days in the calendar's zone, like the schedule, so a clock change
    # doesn't move midnight. Not when the extra days would be over already
    # (the module was off for a while, say): nobody would get the chance.
    def self.extend_nominations!(election, now)
      days = SiteSetting.mod_elections_nomination_extension_days
      return false if days.zero? || election.nominations_extended?
      voting_open_at = election.voting_open_at.in_time_zone(Schedule.zone) + days.days
      return false if voting_open_at <= now
      election.update!(
        voting_open_at: voting_open_at,
        voting_close_at: election.voting_close_at.in_time_zone(Schedule.zone) + days.days,
        nominations_extended_at: now,
      )
      true
    end

    # Under 2**53 so it survives a round trip through JavaScript exactly: the
    # seed is published so anyone can check a drawn lot.
    def self.draw_seed
      SecureRandom.random_number(2**52)
    end

    # A day before Vote Week ends, but never in its first day: a short Vote
    # Week would otherwise send "it's open" and "it ends tomorrow" together.
    def self.remind_now?(election, now)
      return false if election.reminder_sent_at.present? || now >= election.voting_close_at
      now >= [election.voting_close_at - 1.day, election.voting_open_at + 1.day].max
    end

    def self.follow_up(election, step, incumbents: [])
      notify_voters = SiteSetting.mod_elections_notify_voters
      invite = SiteSetting.mod_elections_invite_candidates
      case step
      when :nominations_open
        Notifier.notify(incumbents, election, "on_ballot") if incumbents.any?
        Announcer.nominations_open(election)
        Notifier.enqueue_invites(election, "can_run") if invite
      when :nominations_extended
        Announcer.nominations_extended(election)
        Notifier.enqueue_invites(election, "nominations_extended") if invite
      when :vote_skipped
        Announcer.vote_skipped(election)
        Notifier.notify(User.real.where(admin: true).pluck(:id), election, "vote_skipped")
        Disteleplus.vote_skipped(election)
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

    # An admin ends the current phase early. Nominations an admin closes stay
    # closed, uncontested or not: they chose to stop waiting for candidates.
    def self.end_phase!(election, actor, now = Time.zone.now)
      closing_nominations = false
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
          closing_nominations = true
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
      StaffLog.log(
        actor,
        "mod_election_end_phase",
        election_id: election.id,
        status: election.status,
      )
      advance!(election.reload, now, extend_nominations: !closing_nominations)
    end

    # What an admin can still change, by phase: a date only while it's ahead,
    # and nothing once voting has closed, when more or fewer seats would
    # change who the ballots elect.
    EDITABLE = {
      scheduled: %i[seats nominations_open_at voting_open_at voting_close_at],
      nominating: %i[seats voting_open_at voting_close_at],
      voting: %i[seats voting_close_at],
    }.freeze

    def self.editable(election)
      EDITABLE.fetch(election.status.to_sym, [])
    end

    # An admin changes an election under way: its seats or the dates still
    # ahead. Only what's given and different changes.
    def self.update!(election, actor, now = Time.zone.now, **wanted)
      # First wherever the clock says, as the tick would: in the minute
      # between a deadline and the tick the status still names the phase
      # that ended, and a later end for it would open it again.
      advance!(election, now)
      changed = {}
      election.with_lock do
        raise Error.new(:finished) unless election.unfinished?
        raise Error.new(:edit_closed) if election.closed?
        changes = wanted.compact.reject { |field, value| election.public_send(field) == value }
        raise Error.new(:not_editable) if (changes.keys - editable(election)).any?
        next if changes.empty?

        election.assign_attributes(changes)
        opens, closes = election.voting_open_at, election.voting_close_at
        raise Error.new(:invalid_dates) if election.nominations_open_at >= opens || opens >= closes
        # The end of the phase under way, and anything after it, is ahead,
        # so people still have the time the dates promise.
        raise Error.new(:edit_in_past) if changes.except(:seats).values.any? { |at| at <= now }
        raise Error.new(:invalid_seats) unless election.valid?
        changed = election.changes.transform_values(&:last)
        election.save!
      end
      return election if changed.empty?

      StaffLog.log(actor, "mod_election_edit", election_id: election.id, **changed.symbolize_keys)
      State.changed!
      Announcer.changed(election)
      advance!(election, now)
    end

    # An election an admin starts by hand, for dates off the calendar.
    def self.create!(actor, seats:, nominations_open_at:, voting_open_at:, voting_close_at:)
      unless nominations_open_at && voting_open_at && voting_close_at &&
               nominations_open_at < voting_open_at && voting_open_at < voting_close_at
        raise Error.new(:invalid_dates)
      end
      # Starting it moves it on at once: with Vote Week already open (a
      # mistyped year, say) nobody would get the chance to run.
      raise Error.new(:dates_in_past) if voting_open_at <= Time.zone.now
      election =
        Election.new(
          seats: seats,
          nominations_open_at: nominations_open_at,
          voting_open_at: voting_open_at,
          voting_close_at: voting_close_at,
          created_by: actor,
        )
      raise Error.new(:invalid_dates) unless election.valid?
      creating do
        raise Error.new(:election_in_progress) if Election.unfinished.exists?
        election.save!
      end
      StaffLog.log(actor, "mod_election_create", election_id: election.id)
      advance!(election)
    end
  end
end
