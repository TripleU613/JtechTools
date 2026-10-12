# frozen_string_literal: true

module DiscourseDumbcourse
  class PushController < ::ApplicationController
    requires_plugin "jtech-tools"
    requires_login except: [:server_info]
    before_action :ensure_dumbcourse_enabled, except: [:server_info]

    # GET /<base>/push/info
    # Returns push server URL for SSE connections
    def server_info
      push_url = "#{Discourse.base_url}#{DiscourseDumbcourse.base_path_with_slash}/push/sse"
      render json: { server: push_url, enabled: SiteSetting.dumbcourse_push_enabled }
    end

    # POST /<base>/push/register
    # Register a device for push notifications
    def register
      topic = params[:topic].to_s.strip
      device_id = params[:device_id].to_s.strip

      if topic.blank? || device_id.blank?
        return render json: { error: "topic and device_id required" }, status: :bad_request
      end
      # Both end up in Redis channel names and logs.
      unless topic.match?(/\A[\w\-]{8,80}\z/) && device_id.match?(/\A[\w\-.:]{1,80}\z/)
        return render json: { error: "invalid topic or device_id" }, status: :bad_request
      end
      RateLimiter.new(current_user, "dumbcourse-push-register", 20, 1.hour).performed!

      # Store the mapping: user_id -> { device_id, topic }
      # Use a mutex to prevent concurrent registrations from overwriting each other
      DistributedMutex.synchronize("dumbcourse_push_devices_#{current_user.id}") do
        devices = DiscourseDumbcourse::PushSender.devices(current_user.id)
        if !devices.key?(device_id) && devices.size >= 10
          return render json: { error: "too many devices" }, status: :unprocessable_entity
        end
        devices[device_id] = {
          topic: topic,
          registered_at: Time.now.iso8601,
          user_agent: request.user_agent,
        }
        DiscourseDumbcourse::PushSender.store_devices(current_user.id, devices)
        Rails.logger.info(
          "[Dumbcourse Push] Registered device=#{device_id} topic=#{topic} user=#{current_user.id} total_devices=#{devices.size}",
        )
      end

      render json: { success: true, topic: topic }
    end

    # DELETE /<base>/push/unregister
    # Unregister a device
    def unregister
      device_id = params[:device_id].to_s.strip

      return render json: { error: "device_id required" }, status: :bad_request if device_id.blank?

      DistributedMutex.synchronize("dumbcourse_push_devices_#{current_user.id}") do
        devices = DiscourseDumbcourse::PushSender.devices(current_user.id)
        devices.delete(device_id)
        DiscourseDumbcourse::PushSender.store_devices(current_user.id, devices)
      end

      render json: { success: true }
    end

    # GET /<base>/push/status
    # Check registration status for current user
    def status
      device_id = params[:device_id].to_s.strip
      devices = DiscourseDumbcourse::PushSender.devices(current_user.id)

      if device_id.present?
        device = devices[device_id]
        render json: {
                 registered: device.present?,
                 topic: device&.dig("topic"),
                 device_count: devices.size,
               }
      else
        render json: { device_count: devices.size, devices: devices.keys }
      end
    end

    # GET /<base>/push/preferences
    # Get user's notification preferences
    def preferences
      prefs = PluginStore.get("dumbcourse", "push_prefs_#{current_user.id}") || default_prefs
      render json: prefs
    end

    # PUT /<base>/push/preferences
    # Save user's notification preferences
    def update_preferences
      prefs = {
        direct_replies: params[:direct_replies] != false && params[:direct_replies] != "false",
        watching: params[:watching] != false && params[:watching] != "false",
        mentions: params[:mentions] != false && params[:mentions] != "false",
        messages: params[:messages] != false && params[:messages] != "false",
        quotes: params[:quotes] != false && params[:quotes] != "false",
        likes: params[:likes] == true || params[:likes] == "true",
      }
      PluginStore.set("dumbcourse", "push_prefs_#{current_user.id}", prefs)
      render json: { success: true, preferences: prefs }
    end

    # POST /<base>/push/test
    # Send a test push via Redis publish and return subscriber counts
    def test_push
      devices = DiscourseDumbcourse::PushSender.devices(current_user.id)
      return render json: { error: "No devices registered" }, status: :not_found if devices.empty?

      results = []
      devices.each do |device_id, device_info|
        topic = device_info["topic"]
        next if topic.blank?
        begin
          channel = "dumbcourse_push:#{topic}"
          payload = {
            topic: topic,
            title: "Test push",
            message: "Server test #{Time.now.utc.strftime("%H:%M:%S UTC")}",
            priority: 3,
          }.to_json
          subscribers = Discourse.redis.publish(channel, payload)
          results << { device_id: device_id, topic: topic, subscribers: subscribers }
        rescue => e
          results << { device_id: device_id, topic: topic, error: "#{e.class}: #{e.message}" }
        end
      end
      render json: { device_count: devices.size, results: results }
    end

    private

    def ensure_dumbcourse_enabled
      if !DiscourseDumbcourse.enabled? || !SiteSetting.dumbcourse_push_enabled
        raise Discourse::NotFound
      end
    end

    def default_prefs
      {
        direct_replies: true,
        watching: true,
        mentions: true,
        messages: true,
        quotes: true,
        likes: false,
      }
    end
  end
end
