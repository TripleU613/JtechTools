# frozen_string_literal: true

module DiscourseModCategories
  # Prepended onto ::Search — belt-and-suspenders companion to
  # `SearchIndexerExtension`. The indexer gate deletes whisper rows from
  # `post_search_data`, so tsquery matching cannot surface them in the
  # first place. This filter runs on the result set anyway, so any
  # whisper post that somehow survives (indexer race, backfill hasn't
  # caught up, custom field written after the first index write) is
  # still stripped before the search endpoint serializes it.
  #
  # Order-independence: whether this or SmartSearch's prepend runs first
  # in the `super` chain, variant searches instantiate fresh `Search`
  # objects that traverse the whole chain. So variants get filtered
  # regardless of which entry point runs first.
  #
  # The filter drops whisper `posts` for non-staff viewers, then removes
  # any topic whose only appearance in the result set was via a now-
  # dropped whisper. Topics matched by title stay put — they have their
  # own presence in `topics_id_set` independent of post matches.
  #
  # rescue StandardError → return the base result unchanged so a future
  # Discourse refactor to `Search::GroupedSearchResults` can't 500 a
  # search request. The DB-level gate already prevents leaks; the
  # fallback here only degrades post-filter behavior for a partial
  # deploy state.
  module SearchExtension
    def execute(*args, **kwargs)
      result = super
      begin
        filter_whispers!(result)
      rescue StandardError => e
        # Only the post-filter is rescued — a raise from core `super` above
        # propagates untouched (we're not a circuit breaker for core search).
        # Fail CLOSED: drop every whisper from the result rather than none.
        ::Rails.logger.warn(
          "[jtech-tools] Search whisper post-filter fell back: #{e.class}: #{e.message}",
        )
        begin
          filter_whispers!(result, drop_all: true)
        rescue StandardError
          result.posts.clear if result.respond_to?(:posts) && result.posts.is_a?(Array)
        end
      end
      result
    end

    private

    def filter_whispers!(result, drop_all: false)
      return unless result.respond_to?(:posts)
      posts = result.posts
      return unless posts.is_a?(Array)
      return if posts.empty?

      viewer = @guardian.respond_to?(:user) ? @guardian.user : nil
      return if viewer&.admin? && !drop_all

      post_ids = posts.map(&:id).compact
      return if post_ids.empty?

      blocked =
        if drop_all
          DiscourseModCategories::Whisper.whisper_post_ids(post_ids)
        else
          DiscourseModCategories::Whisper.hidden_post_ids(post_ids, viewer)
        end
      return if blocked.empty?
      blocked_set = blocked.to_set

      dropped_topic_ids = posts.select { |p| blocked_set.include?(p.id) }.map(&:topic_id).uniq
      posts.reject! { |p| blocked_set.include?(p.id) }

      if result.respond_to?(:topics) && result.topics.is_a?(Array)
        remaining_topic_ids = posts.map(&:topic_id).to_set
        result.topics.reject! do |t|
          dropped_topic_ids.include?(t.id) && !remaining_topic_ids.include?(t.id)
        end
      end
    end
  end
end
