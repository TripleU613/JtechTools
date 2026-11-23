# frozen_string_literal: true

# Every page preloads the site's palettes (site.user_color_schemes and the
# default light and dark ones) with every colour of each. With the theme's
# palettes at about fifty colours apiece that was most of a page's weight
# (34 palettes: 107 KB on each page, signed in or not). Nothing in the browser
# reads more than a few of them: core's palette previews and the theme's
# palette menu draw from the colours below, and picking a palette loads its
# stylesheet by its own URL. So each palette goes out with just those.
module DiscourseJtechTheme
  module Palettes
    # color-palette-preview.gjs and color-transformations.js in core, the
    # swatches in the theme's jt-palette-menu.gts
    SHOWN = %w[primary secondary tertiary selected header_background header_primary].freeze

    def self.enabled?
      SiteSetting.jtech_enabled && SiteSetting.jtech_lean_palettes
    end

    # A copy: the list core hands over is its cached fragment
    def self.lean(scheme)
      return scheme unless scheme.is_a?(Hash)
      colors = scheme[:colors] || scheme["colors"]
      return scheme unless colors.is_a?(Array)
      shown =
        colors.filter_map do |color|
          name = color[:name] || color["name"]
          { name:, hex: color[:hex] || color["hex"] } if SHOWN.include?(name)
        end
      scheme.except(:colors, "colors").merge(colors: shown)
    end

    module SiteSerializerExtension
      def user_color_schemes
        list = super
        return list unless Palettes.enabled? && list.is_a?(Array)
        list.map { Palettes.lean(it) }
      end

      def default_light_color_scheme
        Palettes.enabled? ? Palettes.lean(super) : super
      end

      def default_dark_color_scheme
        Palettes.enabled? ? Palettes.lean(super) : super
      end
    end
  end
end
