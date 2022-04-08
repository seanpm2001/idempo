# frozen_string_literal: true

require 'zlib'
require 'msgpack'
require 'base64'
require 'digest'
require 'json'
require 'measurometer'

require_relative "idempo/version"
require_relative "idempo/request_fingerprint"
require_relative "idempo/memory_backend"
require_relative "idempo/redis_backend"
require_relative "idempo/active_record_backend"
require_relative "idempo/malformed_key_error_app"
require_relative "idempo/concurrent_request_error_app"

class Idempo
  DEFAULT_TTL = 30
  SAVED_RESPONSE_BODY_SIZE_LIMIT = 4 * 1024 * 1024

  class Error < StandardError; end

  class ConcurrentRequest < Error; end

  class MalformedIdempotencyKey < Error; end

  def initialize(app, backend: MemoryBackend.new, malformed_key_error_app: MalformedKeyErrorApp, compute_fingerprint_via: RequestFingerprint, concurrent_request_error_app: ConcurrentRequestErrorApp)
    @backend = backend
    @app = app
    @concurrent_request_error_app = concurrent_request_error_app
    @malformed_key_error_app = malformed_key_error_app
    @fingerprint_calculator = compute_fingerprint_via
  end

  def call(env)
    req = Rack::Request.new(env)
    return @app.call(env) if request_verb_idempotent?(req)
    return @app.call(env) unless idempotency_key_header = extract_idempotency_key_from(env)

    # The RFC requires that the Idempotency-Key header value is enclosed in quotes
    idempotency_key_header_value = unquote(idempotency_key_header)
    raise MalformedIdempotencyKey if idempotency_key_header_value == ''

    request_key = @fingerprint_calculator.call(idempotency_key_header_value, req)

    @backend.with_idempotency_key(request_key) do |store|
      if stored_response = store.lookup
        Measurometer.increment_counter('idempo.responses_served_from', 1, from: 'store')
        return from_persisted_response(stored_response)
      end

      status, headers, body = @app.call(env)

      if response_may_be_persisted?(status, headers, body)
        expires_in_seconds = (headers.delete('X-Idempo-Persist-For-Seconds') || DEFAULT_TTL).to_i
        # Body is replaced with a cached version since a Rack response body is not rewindable
        marshaled_response, body = serialize_response(status, headers, body)
        store.store(data: marshaled_response, ttl: expires_in_seconds)
      end

      Measurometer.increment_counter('idempo.responses_served_from', 1, from: 'freshly-generated')
      [status, headers, body]
    end
  rescue MalformedIdempotencyKey
    Measurometer.increment_counter('idempo.responses_served_from', 1, from: 'malformed-idempotency-key')
    @malformed_key_error_app.call(env)
  rescue ConcurrentRequest
    Measurometer.increment_counter('idempo.responses_served_from', 1, from: 'conflict-concurrent-request')
    @concurrent_request_error_app.call(env)
  end

  private

  def from_persisted_response(marshaled_response)
    if marshaled_response[-2..-1] != ':1'
      raise Error, "Unknown serialization of the marshaled response"
    else
      MessagePack.unpack(Zlib.inflate(marshaled_response[0..-3]))
    end
  end

  def serialize_response(status, headers, rack_response_body)
    # Buffer the Rack response body, we can only do that once (it is non-rewindable)
    body_chunks = []
    rack_response_body.each { |chunk|  body_chunks << chunk.dup }
    rack_response_body.close if rack_response_body.respond_to?(:close)

    # Only keep headers which are strings
    stringified_headers = headers.each_with_object({}) do |(header, value), filtered|
      filtered[header] = value if !header.start_with?('rack.') && value.is_a?(String)
    end

    message_packed_str = MessagePack.pack([status, stringified_headers, body_chunks])
    deflated_message_packed_str = Zlib.deflate(message_packed_str) + ":1"
    Measurometer.increment_counter('idempo.response_total_generated_bytes', deflated_message_packed_str.bytesize)
    Measurometer.add_distribution_value('idempo.response_size_bytes', deflated_message_packed_str.bytesize)

    # Add the version specifier at the end, because slicing a string in Ruby at the end
    # (when we unserialize our response again) does a realloc, while slicing at the start
    # does not
    [deflated_message_packed_str, body_chunks]
  end

  def response_may_be_persisted?(status, headers, body)
    return false if headers.delete('X-Idempo-Policy') == 'no-store'
    return false unless status_may_be_persisted?(status)
    return false unless body_size_within_limit?(headers, body)
    true
  end

  def body_size_within_limit?(response_headers, body)
    return response_headers['Content-Length'].to_i <= SAVED_RESPONSE_BODY_SIZE_LIMIT if response_headers['Content-Length']

    return false unless body.is_a?(Array) # Arbitrary iterable of unknown size

    sum_of_string_bytesizes(body) <= SAVED_RESPONSE_BODY_SIZE_LIMIT
  end

  def status_may_be_persisted?(status)
    case status
    when 200..400
      true
    when 429, 425
      false
    when 400..499
      true
    else
      false
    end
  end

  def extract_idempotency_key_from(env)
    env['HTTP_IDEMPOTENCY_KEY'] || env['HTTP_X_IDEMPOTENCY_KEY']
  end

  def request_verb_idempotent?(request)
    request.get? || request.head? || request.options?
  end

  def sum_of_string_bytesizes(in_array)
    in_array.inject(0) { |sum, chunk| sum + chunk.bytesize }
  end

  def unquote(str)
    # Do not use regular expressions so that we don't have to think about a catastrophic lookahead
    double_quote = '"'
    if str.start_with?(double_quote) && str.end_with?(double_quote)
      str[1..-2]
    else
      str
    end
  end
end
