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

    def running_candidates
      candidates.running
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
#  id                  :bigint           not null, primary key
#  nominations_open_at :datetime         not null
#  previewed_at        :datetime
#  published_at        :datetime
#  reminder_sent_at    :datetime
#  result              :jsonb
#  seats               :integer          not null
#  seed                :bigint
#  status              :integer          default("scheduled"), not null
#  voting_close_at     :datetime         not null
#  voting_open_at      :datetime         not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  created_by_id       :bigint
#  published_by_id     :bigint
#  topic_id            :bigint
#
# Indexes
#
#  index_jtech_elections_on_nominations_open_at  (nominations_open_at)
#  index_jtech_elections_on_status               (status)
#
