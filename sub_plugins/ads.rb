# frozen_string_literal: true
# Jtech sub-plugin: ads in the home page's welcome area
# (lib/discourse_jtech_ads.rb, docs/features/ads.md). Instance_eval'd by
# plugin.rb in the Plugin::Instance context.
#
# Settings (config/settings.yml, jtech_ads): jtech_ads_enabled,
# jtech_ads_rotate_seconds, jtech_ads_label, jtech_ads_list

require_relative "../lib/discourse_jtech_ads"
require_relative "../lib/discourse_jtech_ads/manager"

register_asset "stylesheets/lines.scss"
register_svg_icon "thumbs-up"
register_svg_icon "thumbs-down"

after_initialize do
  # Inside the page's preloaded site data: no request of the ads' own
  add_to_serializer(:site, :jt_lines, include_condition: -> { DiscourseJtechAds.enabled? }) do
    DiscourseJtechAds.payload(scope)
  end

  # Visitors' site data is cached; a changed ad reaches them right away
  on(:site_setting_changed) do |name, _old, _new|
    DiscourseJtechAds.clear_cache! if name.to_s.start_with?("jtech_ads_") || name == :jtech_enabled
  end

  # MCP tools (lib/discourse_jtech_ads/mcp_tools.rb): an agent can read, set
  # up, preview and remove ads. Admins only; each stays off until an admin
  # turns it on under Admin → MCP. Older Discourse without the MCP server:
  # nothing to register.
  if respond_to?(:register_mcp_tool)
    require_relative "../lib/discourse_jtech_ads/mcp_tools"
    tools = DiscourseJtechAds::McpTools
    ad = tools::AD_PROPERTIES
    available = -> { SiteSetting.jtech_enabled }

    register_mcp_tool(
      "jtech_ads_get",
      title: "Get the ads",
      description:
        "Returns the ad settings, every ad (running or paused) with its thumbs, and the kit a whole-card ad is built from. Admins only.",
      implementation: tools::Get,
      required_scopes: tools::Get::REQUIRED_SCOPES,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
      risk: :administration,
      availability: available,
    )

    register_mcp_tool(
      "jtech_ads_configure",
      title: "Configure the ads",
      description:
        "Turns ads on or off and sets seconds per ad, the welcome's seconds for new visitors, how long a visitor counts as new, and the label. Admins only.",
      implementation: tools::Configure,
      input_schema: {
        type: "object",
        properties: {
          enabled: {
            type: "boolean",
          },
          rotate_seconds: {
            type: "integer",
            minimum: 5,
            maximum: 600,
          },
          welcome_seconds: {
            type: "integer",
            minimum: 0,
            maximum: 120,
          },
          new_visitor_seconds: {
            type: "integer",
            minimum: 0,
            maximum: 3600,
          },
          label: {
            type: "string",
            maxLength: 40,
          },
        },
        additionalProperties: false,
      },
      required_scopes: tools::Configure::REQUIRED_SCOPES,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
      risk: :administration,
      availability: available,
    )

    register_mcp_tool(
      "jtech_ads_save",
      title: "Save an ad",
      description:
        "Creates an ad, or replaces the one with the same name. Returns what it will show (what the cleaning dropped, if anything) and a preview link. Admins only.",
      implementation: tools::Save,
      input_schema: {
        type: "object",
        properties: ad,
        required: %w[name headline],
        additionalProperties: false,
      },
      required_scopes: tools::Save::REQUIRED_SCOPES,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
      risk: :administration,
      availability: available,
    )

    register_mcp_tool(
      "jtech_ads_delete",
      title: "Delete an ad",
      description:
        "Removes the ad with this name. To stop one without losing it, save it with enabled false. Admins only.",
      implementation: tools::Delete,
      input_schema: {
        type: "object",
        properties: {
          name: ad[:name],
        },
        required: ["name"],
        additionalProperties: false,
      },
      required_scopes: tools::Delete::REQUIRED_SCOPES,
      annotations: {
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
      risk: :destructive,
      availability: available,
    )

    register_mcp_tool(
      "jtech_ads_preview",
      title: "Preview an ad",
      description:
        "A link that shows one ad in the real ad space, for admins only, for an hour, changing nothing else: a saved ad (name only) or a draft (name, headline, text, card). Also returns what the ad will show. Admins only.",
      implementation: tools::Preview,
      input_schema: {
        type: "object",
        properties: ad.slice(:name, :headline, :text, :card),
        additionalProperties: false,
      },
      required_scopes: tools::Preview::REQUIRED_SCOPES,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
      risk: :administration,
      availability: available,
    )
  end
end
