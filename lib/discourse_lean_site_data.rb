# frozen_string_literal: true

# Every page preloads all the categories it may show, and each one carried
# the full definition of every type it is (category_types): title,
# description, every field of its settings form with labels and defaults,
# about 3.8 KB per category, so 113 KB on each page with 47 categories.
# Outside the category editor the browser only asks which types a category
# is (Category#isType, a plugin's `categoryTypes.documentation`), and shows
# a type's name and icon. The editor loads the category again through
# /c/:slug/find_by_slug.json (CategorySerializer), which keeps everything.
module DiscourseLeanSiteData
  # What a type keeps in the preload
  TYPE_KEYS = %i[id name title icon svg_icon].freeze

  def self.enabled?
    SiteSetting.jtech_enabled && SiteSetting.jtech_lean_category_types
  end

  def self.lean_types(types)
    return types unless types.is_a?(Hash)
    types.transform_values { |type| type.is_a?(Hash) ? type.slice(*TYPE_KEYS) : type }
  end

  module SiteCategorySerializerExtension
    def category_types
      types = super
      # Only the site's own list: CategorySerializer (the editor's) and the
      # admin one inherit from this and keep the full definitions
      return types unless instance_of?(::SiteCategorySerializer) && DiscourseLeanSiteData.enabled?
      DiscourseLeanSiteData.lean_types(types)
    end
  end
end
