# frozen_string_literal: true

module DiscourseDiscordMirror
  # Brings one topic's Discord thread in line with the forum: creates the
  # thread, sends missing posts in order, edits changed ones, and removes
  # whatever may no longer be shown. Safe to run any number of times.
  class TopicSync
    # Discord calls per run; a long topic finishes over several runs.
    CALLS_PER_RUN = 25
    # Backfilled threads are archived when quiet, so they don't count toward
    # Discord's cap on active threads.
    QUIET_AFTER = 3.days
    # Digest marking a message to be deleted and sent again, for changes an
    # edit can't carry (the author's name and avatar).
    RESEND = "resend"

    def initialize(topic_id, archive_when_quiet: false)
      @topic_id = topic_id
      @archive_when_quiet = archive_when_quiet
      @calls = 0
    end

    # :done, or :more when the call budget ran out first.
    def run
      DistributedMutex.synchronize("discord_mirror_topic_#{@topic_id}", validity: 10.minutes) do
        sync
      end
    end

    private

    def api
      @api ||= Api.new
    end

    def sync
      topic = Topic.with_deleted.includes(:category).find_by(id: @topic_id)
      thread = MirrorThread.find_by(topic_id: @topic_id)
      first = topic && Post.find_by(topic_id: topic.id, post_number: 1)

      unless topic && first && Visibility.topic?(topic) && Visibility.post?(first, topic: topic)
        retract(thread) if thread
        return :done
      end

      row = Structure.channel_for(topic.category)
      return :done if row.nil?

      if thread && thread.category_id != topic.category_id
        retract(thread)
        thread = nil
      end

      posts = Post.where(topic_id: topic.id).order(:post_number).includes(:user).to_a
      Post.preload_custom_fields(posts, DiscourseModCategories::Whisper.whisper_fields)
      eligible = posts.select { |post| Visibility.post?(post, topic: topic, topic_checked: true) }
      eligible_ids = eligible.map(&:id).to_set

      sent = MirrorMessage.where(topic_id: topic.id).order(:part).group_by(&:post_id)
      sent.each do |post_id, parts|
        parts.each { |part| delete_part(row, part) } unless eligible_ids.include?(post_id)
      end

      unlock(thread, topic) if thread

      eligible.each do |post|
        return :more if @calls >= CALLS_PER_RUN
        thread = sync_post(row, thread, topic, post, sent[post.id] || [])
      end

      finish(thread, topic) if thread
      :done
    end

    def sync_post(row, thread, topic, post, existing)
      parts = Renderer.parts(post)
      name = Renderer.username(post.user)
      avatar = Renderer.avatar_url(post.user)

      parts.each_with_index do |content, index|
        digest = Renderer.digest(content, name, avatar)
        current = existing.find { |m| m.part == index }
        if current&.content_digest == RESEND
          delete_part(row, current)
          current = nil
        end

        if current
          next if current.content_digest == digest
          edit_part(row, current, content, digest)
          next
        end

        body = {
          content: content,
          username: name,
          avatar_url: avatar,
          allowed_mentions: {
            parse: [],
          },
        }

        if thread.nil?
          body[:thread_name] = Renderer.thread_name(topic)
          message =
            call do
              api.webhook(:post, row.webhook_id, row.webhook_token, "", body, query: { wait: true })
            end
          thread =
            MirrorThread.create!(
              topic_id: topic.id,
              category_id: topic.category_id,
              discord_thread_id: message["channel_id"],
              title_sent: body[:thread_name],
            )
        else
          message = post_into(row, thread, body)
        end

        MirrorMessage.create!(
          post_id: post.id,
          topic_id: topic.id,
          part: index,
          discord_message_id: message["id"],
          content_digest: digest,
          user_id: post.user_id,
        )
      end

      existing.select { |m| m.part >= parts.length }.each { |m| delete_part(row, m) }
      thread
    end

    def post_into(row, thread, body)
      in_thread(thread.discord_thread_id) do
        api.webhook(
          :post,
          row.webhook_id,
          row.webhook_token,
          "",
          body,
          query: {
            wait: true,
            thread_id: thread.discord_thread_id,
          },
        )
      end
    end

    # Discord refuses changes in an archived thread; reopen it and retry once.
    def in_thread(thread_id)
      call { yield }
    rescue Api::Error => e
      raise if e.is_a?(Api::RateLimited) || e.is_a?(Api::NotFound)
      raise unless e.status == 400 && e.message.match?(/archived/i)
      call { api.bot(:patch, "/channels/#{thread_id}", { archived: false }) }
      call { yield }
    end

    def edit_part(row, message, content, digest)
      in_thread(thread_id_for(message)) do
        api.webhook(
          :patch,
          row.webhook_id,
          row.webhook_token,
          "/messages/#{message.discord_message_id}",
          { content: content, allowed_mentions: { parse: [] } },
          query: {
            thread_id: thread_id_for(message),
          },
        )
      end
      message.update!(content_digest: digest)
    rescue Api::NotFound
      message.destroy!
    end

    def delete_part(row, message)
      begin
        in_thread(thread_id_for(message)) do
          api.webhook(
            :delete,
            row.webhook_id,
            row.webhook_token,
            "/messages/#{message.discord_message_id}",
            query: {
              thread_id: thread_id_for(message),
            },
          )
        end
      rescue Api::NotFound
        nil
      end
      message.destroy!
    end

    def thread_id_for(message)
      MirrorThread.where(topic_id: message.topic_id).pick(:discord_thread_id)
    end

    def unlock(thread, topic)
      return unless thread.locked && !(topic.closed || topic.archived)
      call do
        api.bot(:patch, "/channels/#{thread.discord_thread_id}", { locked: false, archived: false })
      end
      thread.update!(locked: false)
    end

    def finish(thread, topic)
      changes = {}
      title = Renderer.thread_name(topic)
      changes[:name] = title if thread.title_sent != title
      lock = topic.closed || topic.archived
      changes[:locked] = true if lock && !thread.locked
      if @archive_when_quiet && (topic.bumped_at.nil? || topic.bumped_at < QUIET_AFTER.ago)
        changes[:archived] = true
      end

      if changes.any?
        begin
          call { api.bot(:patch, "/channels/#{thread.discord_thread_id}", changes) }
        rescue Api::NotFound
          forget(thread)
          return
        end
      end

      thread.update!(title_sent: title, locked: lock || thread.locked)
      thread.touch
    end

    def retract(thread)
      begin
        call { api.bot(:delete, "/channels/#{thread.discord_thread_id}") }
      rescue Api::NotFound
        nil
      end
      forget(thread)
    end

    def forget(thread)
      MirrorMessage.where(topic_id: thread.topic_id).delete_all
      thread.destroy!
    end

    def call
      @calls += 1
      yield
    end
  end
end
