# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseDisteleplus::TelegramUploadSender do
  let(:api) { instance_double(DiscourseDisteleplus::TelegramApi) }
  let(:sender) { described_class.new(api: api) }
  let(:upload) do
    instance_double(
      Upload,
      extension: "apk",
      original_filename: "tool.apk",
      filesize: 100,
      url: "/uploads/default/original/tool.apk",
    )
  end
  let(:telegram_result) do
    DiscourseDisteleplus::TelegramApi::Result.new(ok: true, result: { "message_id" => 123 })
  end

  it "uploads the file into the configured Telegram topic" do
    io = StringIO.new("binary")
    allow(described_class).to receive(:upload_io).and_return(io)
    allow(api).to receive(:call_multipart).and_return(telegram_result)

    delivery =
      sender.send(
        upload: upload,
        caption: "<b>tool.apk</b>",
        chat_id: "-1005",
        topic_id: 77,
        max_bytes: 1.megabyte,
      )

    expect(api).to have_received(:call_multipart).with(
      "sendDocument",
      a_hash_including(chat_id: "-1005", message_thread_id: 77, parse_mode: "HTML"),
      file_field: "document",
      io: io,
      filename: "tool.apk",
    )
    expect(delivery.file_copied).to eq(true)
    expect(delivery.message["message_id"]).to eq(123)
  end

  it "sends a forum link instead of claiming an oversized file was copied" do
    allow(upload).to receive(:filesize).and_return(60.megabytes)
    allow(api).to receive(:call).and_return(telegram_result)

    delivery =
      sender.send(
        upload: upload,
        caption: "<b>tool.apk</b>",
        chat_id: "-1005",
        topic_id: 77,
        max_bytes: 50.megabytes,
      )

    expect(api).to have_received(:call).with(
      "sendMessage",
      a_hash_including(
        message_thread_id: 77,
        text: a_string_including("Open file on #{SiteSetting.title}"),
      ),
    )
    expect(delivery.file_copied).to eq(false)
  end
end
