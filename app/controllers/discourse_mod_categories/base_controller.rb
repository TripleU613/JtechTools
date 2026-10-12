# frozen_string_literal: true

module DiscourseModCategories
  # What the mod tools' controllers share: the module's switch, a feature's
  # own switch, and a topic the user can see. `requires_login` stays in each
  # controller: core stores it per class, so it wouldn't carry over.
  class BaseController < ::ApplicationController
    requires_plugin "jtech-tools"

    private

    def ensure_module_enabled
      raise Discourse::NotFound unless DiscourseModCategories.enabled?
    end

    def ensure_feature!(setting)
      raise Discourse::NotFound unless SiteSetting.public_send(setting)
    end

    def find_topic!
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::NotFound if topic.nil? || !guardian.can_see_topic?(topic)
      topic
    end
  end
end
