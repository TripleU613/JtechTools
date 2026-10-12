# frozen_string_literal: true

module Jobs
  # Runs shortly after a conversation poll's close time: makes sure the poll
  # really closed (core's own close job owns that; this is a belt-and-braces
  # race guard), then posts a results summary into the conversation, which
  # bridges to Telegram like any other message.
  class DisteleplusPollCloseAnnouncement < ::Jobs::Base
    def execute(args)
      return unless DiscourseDisteleplus::Polls.enabled?

      message = DiscourseDisteleplus::Message.find_by(id: args[:message_id])
      return if message.nil? || message.deleted? || message.poll_post_id.blank?

      post = ::Post.find_by(id: message.poll_post_id)
      poll = post && ::Poll.find_by(post: post)
      return unless poll

      if poll.open? && poll.close_at&.past?
        begin
          ::DiscoursePoll::Poll.toggle_status(
            Discourse.system_user,
            post.id,
            poll.name,
            "closed",
            false,
          )
        rescue StandardError
          # Core's close job may win the race — announcing is what matters.
        end
        poll.reload
      end
      return if poll.open?

      raw = DiscourseDisteleplus::Polls.results_markdown(message)
      return if raw.blank?

      announcement =
        DiscourseDisteleplus::MessageService.new(actor: Discourse.system_user).create!(
          raw: raw,
          reply_to_id: message.id,
          notify: false,
        )
      notify_author(message, announcement)
    rescue StandardError => e
      Rails.logger.warn(
        "#{DiscourseDisteleplus::LOG_TAG} poll close announcement failed: #{e.message}",
      )
    end

    private

    # The poll's author gets a bell (and toast) pointing at the results.
    def notify_author(poll_message, announcement)
      author = poll_message.user
      return if author.nil? || author.bot?

      question = DiscourseDisteleplus::Polls.question_text(poll_message.raw).presence
      Notification.create!(
        notification_type: Notification.types[:custom],
        user_id: author.id,
        high_priority: true,
        data: {
          message:
            I18n.t(
              "disteleplus.poll_closed_notification",
              question: question,
              default: "Your poll closed: #{question}",
            ),
          title: I18n.t("disteleplus.title", default: "Disteleplus"),
          url: "/disteleplus#m#{announcement.id}",
          excerpt: question,
          disteleplus_message_id: announcement.id,
          disteleplus: true,
          disteleplus_kind: "poll_closed",
        }.to_json,
      )
    rescue StandardError => e
      Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} poll close notify failed: #{e.message}")
    end
  end
end
