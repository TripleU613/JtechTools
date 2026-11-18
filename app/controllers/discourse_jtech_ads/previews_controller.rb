# frozen_string_literal: true

module DiscourseJtechAds
  # Admin previews: one ad in the real ad space, only for the admin who
  # opens the link, for an hour; nothing else changes
  class PreviewsController < ::Admin::AdminController
    requires_plugin "jtech-tools"

    # The saved ads' names, for the Ads tab's preview picker
    def index
      render json: { names: Manager.entries.map { it["name"] } }
    end

    def create
      preview =
        if params[:name].present? && params[:headline].blank?
          Manager.preview!(name: params[:name].to_s)
        else
          entry = params.permit(:name, :headline, :text, :card).to_h
          entry["name"] = entry["name"].presence || "draft"
          Manager.preview!(entry:)
        end
      render json: preview
    rescue Manager::Error => e
      render_json_error(e.message, status: 422)
    end

    def show
      line = Manager.preview_line(params[:token]) or raise Discourse::NotFound
      render json: line
    end
  end
end
