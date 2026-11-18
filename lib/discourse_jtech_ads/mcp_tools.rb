# frozen_string_literal: true

module ::DiscourseJtechAds
  # Discourse MCP server tools (sub_plugins/ads.rb registers them): an agent
  # can read, set up, preview and remove ads. Admins only, and each tool
  # stays off until an admin turns it on under Admin → MCP.
  module McpTools
    READ_SCOPE = "mcp:jtech-ads:read"
    WRITE_SCOPE = "mcp:jtech-ads:write"

    AD_PROPERTIES = {
      name: {
        type: "string",
        maxLength: 60,
        description: "Unique; shown nowhere. Thumbs are counted per name.",
      },
      enabled: {
        type: "boolean",
        description: "Running. false keeps it saved without showing it.",
      },
      headline: {
        type: "string",
        maxLength: 120,
        description: "Inline HTML: text, <a href>, <b>, <i>…",
      },
      text: {
        type: "string",
        maxLength: 400,
        description: "The line under the headline. Inline HTML.",
      },
      card: {
        type: "string",
        maxLength: 4000,
        description:
          "Optional whole-card HTML built from the kit (see jtech_ads_get: kit). Fills the fixed ad space; never changes its size.",
      },
      audience: {
        type: "string",
        enum: AUDIENCES,
      },
      groups: {
        type: "array",
        items: {
          type: "integer",
        },
        description: "Group ids, with audience groups.",
      },
      weight: {
        type: "integer",
        minimum: 1,
        maximum: 10,
      },
      starts_at: {
        type: "string",
        description: "ISO 8601, optional.",
      },
      ends_at: {
        type: "string",
        description: "ISO 8601, optional.",
      },
    }.freeze

    module Support
      module_function

      def admin!(request_context)
        request_context.guardian.ensure_is_admin!
        request_context.user
      end

      def result(value)
        DiscourseMcp::ToolHelpers.text_and_structured(value.as_json)
      end

      def guard
        yield
      rescue Manager::Error => e
        raise DiscourseMcp::ToolError, e.message
      end
    end

    class Get
      REQUIRED_SCOPES = [READ_SCOPE].freeze

      def self.call(arguments:, request_context:)
        Support.admin!(request_context)
        Support.result(
          settings: Manager.settings,
          ads: Manager.entries,
          kit: {
            classes: KIT,
            card_tags: CARD_TAGS,
            inline_tags: TAGS,
            notes:
              "The ad space has a fixed height (about 224px on phones, 272px wide); content is cut, never grown into. jl-split = main column + side column (the side hides on phones). Docs: docs/features/ads.md in jtech-tools.",
          },
        )
      end
    end

    class Configure
      REQUIRED_SCOPES = [WRITE_SCOPE].freeze

      def self.call(arguments:, request_context:)
        user = Support.admin!(request_context)
        Support.guard { Support.result(settings: Manager.configure!(arguments, by: user)) }
      end
    end

    class Save
      REQUIRED_SCOPES = [WRITE_SCOPE].freeze

      def self.call(arguments:, request_context:)
        user = Support.admin!(request_context)
        Support.guard do
          entry = Manager.save!(arguments, by: user)
          Support.result(
            saved: entry,
            shows_as: Manager.report(entry),
            preview: Manager.preview!(name: entry["name"]),
          )
        end
      end
    end

    class Delete
      REQUIRED_SCOPES = [WRITE_SCOPE].freeze

      def self.call(arguments:, request_context:)
        user = Support.admin!(request_context)
        Support.guard do
          Manager.delete!(arguments.fetch("name"), by: user)
          Support.result(deleted: arguments.fetch("name"))
        end
      end
    end

    class Preview
      REQUIRED_SCOPES = [READ_SCOPE].freeze

      def self.call(arguments:, request_context:)
        Support.admin!(request_context)
        Support.guard do
          if arguments["name"].present? && arguments["headline"].blank?
            Support.result(
              preview: Manager.preview!(name: arguments["name"]),
              shows_as: Manager.report(Manager.entries.find { it["name"] == arguments["name"] }),
            )
          else
            entry = arguments.merge("name" => arguments["name"].presence || "draft")
            Support.result(preview: Manager.preview!(entry:), shows_as: Manager.report(entry))
          end
        end
      end
    end
  end
end
