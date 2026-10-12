# frozen_string_literal: true

module DiscourseModElections
  # Bell notifications. They link to /elections and say which step it is;
  # never anything about anyone's ballot.
  #
  # Uses the `custom` notification type like the plugin's other features;
  # the shared client renderer (lib/mod-note-notification.ts) picks these up
  # by the `mod_election` marker in data.
  module Notifier
    KINDS = %w[on_ballot voting_open reminder closed results disqualified seat_filled].freeze
    # Being taken off the ballot can happen twice (taken off, put back,
    # taken off again); everything else happens once per election.
    REPEATABLE = %w[disqualified].freeze
    PAGE = "/elections"
    BATCH = 500

    def self.notify(user_ids, election, kind)
      raise ArgumentError, "unknown kind #{kind}" if KINDS.exclude?(kind)
      data = payload(election, kind).to_json
      User
        .where(id: user_ids)
        .find_in_batches(batch_size: BATCH) do |users|
          # A job retried after failing halfway skips whoever already has it.
          done = REPEATABLE.include?(kind) ? [] : already_notified(users.map(&:id), election, kind)
          users.each do |user|
            next if done.include?(user.id)
            Notification.create!(
              notification_type: Notification.types[:custom],
              user_id: user.id,
              high_priority: %w[voting_open reminder closed].include?(kind),
              data: data,
            )
          end
        end
    end

    # Matched on the JSON text: notification data is a string column, and
    # this payload's keys always come out in the same order.
    def self.already_notified(user_ids, election, kind)
      Notification
        .where(user_id: user_ids, notification_type: Notification.types[:custom])
        .where(
          "data LIKE ?",
          "%\"mod_election_kind\":#{kind.to_json},\"mod_election_id\":#{election.id},%",
        )
        .distinct
        .pluck(:user_id)
    end

    # Everyone on the voter list, or for the reminder only those who haven't
    # voted. Can be thousands of people, so it runs in a job.
    def self.enqueue_voters(election, kind)
      Jobs.enqueue(:mod_elections_notify_voters, election_id: election.id, kind: kind)
    end

    def self.voter_ids(election, kind)
      ids = Voter.where(election_id: election.id).where.not(user_id: nil)
      if kind == "reminder"
        # Without the NULLs (deleted accounts), or NOT IN would match nobody.
        voted = Ballot.where(election_id: election.id).where.not(user_id: nil).select(:user_id)
        ids = ids.where.not(user_id: voted)
      end
      ids.pluck(:user_id)
    end

    def self.payload(election, kind)
      {
        mod_election: true,
        mod_election_kind: kind,
        mod_election_id: election.id,
        message: "mod_elections.notifications.#{kind}",
        title: "mod_elections.title",
        url: kind == "closed" ? "/admin/plugins/jtech-tools/mod-elections" : PAGE,
        display_username: "",
        excerpt: I18n.t("mod_elections.notifications.#{kind}"),
      }
    end
  end
end
