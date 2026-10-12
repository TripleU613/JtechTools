# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseDumbcourse::PushSender do
  fab!(:user)
  fab!(:other_user, :user)

  def notify(recipient)
    Notification.create!(
      notification_type: Notification.types[:custom],
      user_id: recipient.id,
      data: { message: "hello" }.to_json,
    )
  end

  before do
    SiteSetting.dumbcourse_enabled = true
    SiteSetting.dumbcourse_push_enabled = true
    DiscourseDumbcourse::PushSender.store_devices(
      user.id,
      { "phone" => { "topic" => "abc", "registered_at" => Time.now.iso8601 } },
    )
  end

  it "queues a push on a new notification for someone with a registered device" do
    notification = notify(user)
    expect_job_enqueued(job: :dumbcourse_push_notify, args: { notification_id: notification.id })
  end

  it "queues nothing for someone without a device" do
    notification = notify(other_user)
    expect(
      job_enqueued?(job: :dumbcourse_push_notify, args: { notification_id: notification.id }),
    ).to eq(false)
  end

  it "queues nothing while pushes are off" do
    SiteSetting.dumbcourse_push_enabled = false
    notification = notify(user)
    expect(
      job_enqueued?(job: :dumbcourse_push_notify, args: { notification_id: notification.id }),
    ).to eq(false)
  end
end
