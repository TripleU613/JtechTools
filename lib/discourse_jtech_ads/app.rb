# frozen_string_literal: true

module ::DiscourseJtechAds
  # An "app" ad: whole-card HTML with CSS of its own. In the browser it runs
  # inside a closed shadow root in the fixed ad space, so its selectors,
  # animations and SVG ids are its own and can't reach the page, the label,
  # the thumbs or the space's size.
  #
  # Nothing may load from anywhere: CSS that could fetch something (url(),
  # @import, fonts…) is refused whole, never repaired, and the HTML has no
  # images, media, frames, scripts, forms or styles of its own. Search and
  # sign-up come from placeholders the plugin fills itself.
  module App
    MAX_HTML = 8000
    MAX_CSS = 8000
    MAX_ELEMENTS = 400

    HTML_TAGS = (CARD_TAGS + %w[h1 nav aside article figure figcaption strong em dl dt dd]).freeze
    SVG_TAGS = %w[
      svg
      g
      path
      circle
      ellipse
      rect
      line
      polyline
      polygon
      defs
      lineargradient
      radialgradient
      stop
      text
      tspan
      title
    ].freeze
    SVG_ATTRIBUTES = %w[
      viewbox
      xmlns
      preserveaspectratio
      d
      cx
      cy
      r
      rx
      ry
      x
      y
      x1
      x2
      y1
      y2
      dx
      dy
      width
      height
      points
      fill
      fill-opacity
      fill-rule
      stroke
      stroke-width
      stroke-opacity
      stroke-linecap
      stroke-linejoin
      stroke-dasharray
      stroke-dashoffset
      opacity
      transform
      offset
      stop-color
      stop-opacity
      gradientunits
      gradienttransform
      fx
      fy
      text-anchor
      font-size
      font-weight
      letter-spacing
    ].freeze
    ATTRIBUTES = %w[href title class id dir role aria-hidden aria-label].freeze
    # Filled in the browser by the plugin: a search box, and sign-up/log-in
    # for visitors
    WIDGETS = %w[jl-search jl-auth].freeze

    # CSS that could load or run anything: refused whole
    CSS_REFUSED = [
      ["\\", "a backslash (escapes can hide anything)"],
      %w[url( url()],
      %w[image-set( image-set()],
      %w[image( image()],
      %w[src( src()],
      %w[expression( expression()],
      %w[javascript: javascript:],
      %w[behavior behavior],
      %w[-moz-binding -moz-binding],
      ["</", "a closing tag"],
    ].freeze
    AT_RULES = %w[keyframes -webkit-keyframes media container supports].freeze

    class << self
      # [css, nil] when it's safe, [nil, reason] when it's refused
      def clean_css(css)
        css = css.to_s.strip
        return nil, nil if css.empty?
        return nil, "CSS is over #{MAX_CSS} characters" if css.length > MAX_CSS

        lowered = css.downcase
        CSS_REFUSED.each do |needle, name|
          return nil, "CSS refused: it contains #{name}" if lowered.include?(needle)
        end
        lowered
          .scan(/@([a-z-]+)/)
          .flatten
          .uniq
          .each do |rule|
            return nil, "CSS refused: @#{rule} isn't allowed" if AT_RULES.exclude?(rule)
          end
        [css, nil]
      end

      # [html, dropped notes]
      def clean_html(html)
        return "", [] if html.blank?
        return "", ["HTML is over #{MAX_HTML} characters"] if html.length > MAX_HTML

        notes = []
        fragment = Nokogiri::HTML5.fragment(html.to_s)
        return "", ["over #{MAX_ELEMENTS} elements"] if fragment.css("*").size > MAX_ELEMENTS

        fragment
          .xpath(".//*")
          .to_a
          .each do |node|
            next if node.document.nil? || node.parent.nil?

            name = node.name.downcase
            in_svg =
              name == "svg" || node.ancestors.any? { it.respond_to?(:name) && it.name == "svg" }
            allowed = in_svg ? SVG_TAGS.include?(name) : HTML_TAGS.include?(name)
            unless allowed
              notes << "<#{name}>"
              node.remove
              next
            end

            node.attribute_nodes.each do |attribute|
              key = attribute.name.downcase
              value = attribute.value.to_s
              ok =
                if in_svg
                  (
                    SVG_ATTRIBUTES.include?(key) ||
                      %w[class id role aria-hidden aria-label].include?(key)
                  ) && safe_svg_value?(value)
                else
                  ATTRIBUTES.include?(key)
                end
              ok &&= safe_href?(value) if key == "href"
              ok &&= value.match?(/\A[A-Za-z][\w-]{0,40}\z/) if key == "id"
              next if ok

              notes << "attribute #{key}"
              node.remove_attribute(attribute.name)
            end
          end

        DiscourseJtechAds.send(:safe_links, fragment)
        [fragment.to_html, notes.uniq]
      end

      private

      # Inside SVG only fragment references: url(#id)
      def safe_svg_value?(value)
        lowered = value.downcase
        return false if lowered.include?("javascript:") || lowered.include?("\\")
        lowered.scan(/url\(([^)]*)\)/).flatten.all? { it.strip.delete(%("')).start_with?("#") }
      end

      def safe_href?(href)
        href.start_with?("/") || href.match?(%r{\A(https?:)?//}i) || href.start_with?("mailto:")
      end
    end
  end
end
