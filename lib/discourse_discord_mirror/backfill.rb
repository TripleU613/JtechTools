# frozen_string_literal: true

module DiscourseDiscordMirror
  # Which topics to send, and where the backfill got to. Also finds mirrored
  # topics whose forum side changed after their last sync.
  module Backfill
    module_function

    STORE = "discord_mirror"
    CURSOR = "backfill_cursor"
    DONE = "backfill_done_days"
    BATCH = 100

    def topics(days)
      Enumerator.new do |yielder|
        loop do
          batch = next_batch(days)
          break if batch.empty?
          batch.each { |topic| yielder << topic }
        end
      end
    end

    def next_batch(days)
      ids = Structure.categories.map(&:id)
      return [] if ids.empty?

      scope =
        Topic
          .where(category_id: ids, archetype: Archetype.default, visible: true, deleted_at: nil)
          .where("bumped_at > ?", days.days.ago)
          .where.not(id: Category.where.not(topic_id: nil).select(:topic_id))
          .order(:bumped_at, :id)
          .limit(BATCH)

      cursor = PluginStore.get(STORE, CURSOR)
      if cursor
        at = Time.zone.parse(cursor["at"])
        scope = scope.where("(bumped_at, id) > (?, ?)", at, cursor["id"].to_i)
      end
      scope.to_a
    end

    def advance(topic)
      PluginStore.set(STORE, CURSOR, { "at" => topic.bumped_at.iso8601(6), "id" => topic.id })
    end

    def finish
      PluginStore.set(STORE, DONE, SiteSetting.discord_mirror_backfill_days.to_i)
    end

    def restart
      PluginStore.remove(STORE, CURSOR)
      PluginStore.remove(STORE, DONE)
    end

    def stale_topic_ids(limit: 500)
      DB.query_single(<<~SQL, field: DiscourseModCategories::Whisper.targets_field, limit: limit)
        SELECT t.topic_id
        FROM discord_mirror_threads t
        LEFT JOIN topics tp ON tp.id = t.topic_id
        WHERE tp.id IS NULL
          OR tp.deleted_at IS NOT NULL
          OR NOT tp.visible
          OR tp.archetype <> 'regular'
          OR tp.category_id <> t.category_id
          OR (tp.closed OR tp.archived) <> t.locked
          OR tp.updated_at > t.updated_at
        UNION
        SELECT m.topic_id
        FROM discord_mirror_messages m
        JOIN discord_mirror_threads t ON t.topic_id = m.topic_id
        LEFT JOIN posts p ON p.id = m.post_id
        WHERE p.id IS NULL
          OR p.deleted_at IS NOT NULL
          OR p.hidden
          OR p.post_type <> 1
          OR p.updated_at > t.updated_at
          OR EXISTS (
            SELECT 1 FROM post_custom_fields f
            WHERE f.post_id = m.post_id AND f.name = :field
          )
        LIMIT :limit
      SQL
    end
  end
end
