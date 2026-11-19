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
        maxLength: 8000,
        description:
          "Optional whole-card HTML. Without css: built from the kit's classes. With css: an app (see jtech_ads_get: app). Fills the fixed ad space; never changes its size.",
      },
      css: {
        type: "string",
        maxLength: 8000,
        description:
          "Optional CSS for the card, making it an app in its own shadow root. Refused whole if it could load anything (url(), @import, fonts, backslashes…). Use the --jl-* variables to match the theme.",
      },
      house: {
        type: "boolean",
        description: "The forum's own content only: no Ad label, no thumbs.",
      },
      intro: {
        type: "boolean",
        description: "Shown first to new visitors, as the welcome.",
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
          app: {
            how:
              "An app is card HTML plus css. It runs in a closed shadow root inside the fixed ad space: up to 272px tall on wide screens and the content column's width; on phones (up to 600px wide) a card of its own, 320px tall and about 360-400px wide, so stack a picture band over the words there. It never grows: anything that doesn't fit is cut. Use your own class names. Theme colours: var(--jl-fg), --jl-muted, --jl-border, --jl-raised, --jl-accent, --jl-accent-fg, --jl-radius, --jl-radius-lg; the page's fonts inherit. The kit's classes work inside too.",
            reserved:
              "The space draws its own label ('Ad') and thumbs above the app, unless the ad is house. Wide screens: label top right (about 40x22px), thumbs bottom right (about 90x34px). Phones (card under 520px wide): label and thumbs share one bar at the top right (about 130x40px) and the bottom is free. Leave those areas clear; the app can't remove or cover them.",
            widgets:
              "<div class=\"jl-search\"></div> becomes a search box; <div class=\"jl-auth\"></div> becomes Sign up / Log in for visitors (nothing for members). Forms and inputs are otherwise not allowed.",
            html:
              "Block and inline tags, inline SVG (shapes, gradients, text; no use/image/foreignObject/animate), links. No images, video, iframes, scripts, styles, forms. Up to #{App::MAX_HTML} characters and #{App::MAX_ELEMENTS} elements.",
            css:
              "Up to #{App::MAX_CSS} characters. Allowed at-rules: #{App::AT_RULES.join(", ")}. Refused whole if it contains url(), image-set(), image(), src(), @import, @font-face, a backslash, expression(), behavior or -moz-binding: nothing may load from anywhere.",
            performance:
              "Animate transform and opacity only, a few elements at a time; no huge blurs or shadows animated. Animations pause when the space is off screen or the tab is hidden, and stop for reduced motion.",
          },
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
