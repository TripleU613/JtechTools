# frozen_string_literal: true

module DiscourseModElections
  # One round of mod elections: nominations, then Vote Week, then the count.
  class Election < ActiveRecord::Base
    self.table_name = "jtech_elections"

    has_many :candidates, class_name: "DiscourseModElections::Candidate", dependent: :delete_all
    has_many :voters, class_name: "DiscourseModElections::Voter", dependent: :delete_all
    has_many :ballots, class_name: "DiscourseModElections::Ballot", dependent: :delete_all
    belongs_to :topic, optional: true
    belongs_to :created_by, class_name: "User", optional: true
    belongs_to :published_by, class_name: "User", optional: true

    enum :status, { scheduled: 0, nominating: 1, voting: 2, closed: 3, published: 4, cancelled: 5 }

    # Still going somewhere: not yet published or cancelled.
    UNFINISHED = %i[scheduled nominating voting closed].freeze
    # Ballots and the candidate list can still change.
    BEFORE_CLOSE = %i[scheduled nominating voting].freeze

    scope :unfinished, -> { where(status: UNFINISHED) }

    validates :seats, numericality: { only_integer: true, greater_than: 0, less_than: 100 }
    validate :dates_in_order

    def unfinished?
      UNFINISHED.include?(status.to_sym)
    end

    # By the clock as well as the status: the tick job moves the status a
    # minute or so late, and nothing may slip in after a deadline.
    def taking_nominations?(now = Time.zone.now)
      nominating? && now >= nominations_open_at && now < voting_open_at
    end

    def taking_votes?(now = Time.zone.now)
      voting? && now >= voting_open_at && now < voting_close_at
    end

    # Candidates can change their statement through Vote Week, not after.
    def taking_statements?(now = Time.zone.now)
      taking_nominations?(now) || taking_votes?(now)
    end

    def before_close?
      BEFORE_CLOSE.include?(status.to_sym)
    end

    # No more candidates than seats: the count elects them all whatever the
    # ballots say, so there's nothing to vote on.
    def uncontested?
      candidates.running.count <= seats
    end

    # Nominations closed uncontested, so there was no Vote Week.
    def vote_skipped?
      vote_skipped_at.present?
    end

    def nominations_extended?
      nominations_extended_at.present?
    end

    # Raises the reason a change can't happen in this phase, if it can't:
    # :nominations, :statements and :votes go by the clock too; :closed is
    # after Vote Week and before publishing; :unfinished is anything not yet
    # over.
    def check_phase!(phase, now = Time.zone.now)
      case phase
      when :nominations
        raise Error.new(:not_nominating) unless taking_nominations?(now)
      when :statements
        raise Error.new(:statements_closed) unless taking_statements?(now)
      when :votes
        raise Error.new(:not_voting) unless taking_votes?(now)
      when :closed
        raise Error.new(:finished) unless unfinished?
        raise Error.new(:not_closed) unless closed?
      when :unfinished
        raise Error.new(:finished) unless unfinished?
      else
        raise ArgumentError, "unknown phase #{phase}"
      end
    end

    # Every change to an election runs here: under its row lock (which
    # publishing takes too), in the phase it belongs to.
    def change_in!(phase)
      with_lock do
        check_phase!(phase)
        yield
      end
    end

    # "January 2027", from the calendar's zone: a reader in Los Angeles
    # still sees January for an election that opened at midnight in New
    # York on the 1st.
    def month_label
      I18n.l(nominations_open_at.in_time_zone(Schedule.zone).to_date, format: "%B %Y")
    end

    # When the current phase ends, for the page and the banner.
    def phase_ends_at
      if scheduled?
        nominations_open_at
      elsif nominating?
        voting_open_at
      elsif voting?
        voting_close_at
      end
    end

    private

    def dates_in_order
      return if nominations_open_at.blank? || voting_open_at.blank? || voting_close_at.blank?
      # Equal is allowed: an admin can end a phase the moment it starts.
      if voting_open_at < nominations_open_at || voting_close_at < voting_open_at
        errors.add(:voting_open_at, :invalid)
      end
    end
  end
end

# == Schema Information
#
# Table name: jtech_elections
#
#  id                      :bigint           not null, primary key
#  nominations_extended_at :datetime
#  nominations_open_at     :datetime         not null
#  previewed_at            :datetime
#  published_at            :datetime
#  reminder_sent_at        :datetime
#  result                  :jsonb
#  seats                   :integer          not null
#  seed                    :bigint
#  status                  :integer          default("scheduled"), not null
#  vote_skipped_at         :datetime
#  voting_close_at         :datetime         not null
#  voting_open_at          :datetime         not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  created_by_id           :bigint
#  published_by_id         :bigint
#  topic_id                :bigint
#
# Indexes
#
#  index_jtech_elections_on_nominations_open_at  (nominations_open_at)
#  index_jtech_elections_on_status               (status)
#
