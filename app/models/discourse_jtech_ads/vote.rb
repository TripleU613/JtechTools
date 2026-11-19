# frozen_string_literal: true

module DiscourseJtechAds
  # A member's thumbs up (1) or down (-1) on an ad, one per member and ad.
  # Keyed by the ad's key (a hash of its name), so renaming an ad starts its
  # count over.
  class Vote < ActiveRecord::Base
    self.table_name = "jtech_ad_votes"

    belongs_to :user

    validates :ad_key, format: DiscourseJtechAds::KEY_FORMAT
    validates :value, inclusion: DiscourseJtechAds::VOTE_VALUES

    # { key => { up:, down: } } for the given ads, in one query
    def self.counts(keys)
      where(ad_key: keys)
        .group(:ad_key, :value)
        .count
        .each_with_object({}) do |((key, value), count), counts|
          counts[key] ||= { up: 0, down: 0 }
          counts[key][value.positive? ? :up : :down] = count
        end
    end
  end
end
