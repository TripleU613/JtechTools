# frozen_string_literal: true

require "openssl"

module DiscourseDiscordChat
  # Discord signs each interaction with the app's Ed25519 key over the
  # timestamp header followed by the raw body. Plain OpenSSL rather than the
  # ed25519 gem: core's Gemfile marks that gem for removal.
  module Signature
    # DER SubjectPublicKeyInfo header for a raw 32-byte Ed25519 key, so
    # OpenSSL can load the hex key Discord shows in the Developer Portal.
    SPKI_PREFIX = ["302a300506032b6570032100"].pack("H*")

    def self.valid?(public_key:, signature:, timestamp:, body:)
      public_key = public_key.to_s.strip
      signature = signature.to_s
      timestamp = timestamp.to_s
      return false unless public_key.match?(/\A\h{64}\z/)
      return false unless signature.match?(/\A\h{128}\z/)
      return false if timestamp.empty?

      key = OpenSSL::PKey.read(SPKI_PREFIX + [public_key].pack("H*"))
      key.verify(nil, [signature].pack("H*"), timestamp.b + body.to_s.b)
    rescue OpenSSL::PKey::PKeyError
      false
    end
  end
end
