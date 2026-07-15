# frozen_string_literal: true

require "json"
require_relative "metrics"

module SpaceInferenceGateway
  module ErrorRelay
    JSON_HEADERS = { "content-type" => "application/json" }.freeze

    # Base relay — current I07 behavior for true-OAI upstreams (llama-server,
    # or any upstream whose error body is already a conformant OAI error object).
    # Retained intact so a future llama-server registry entry selects this class.
    class Oai
      # Returns a Rack triple [status, headers, [body]] that mirrors the upstream
      # error in the client's API flavor (:oai or :ant).
      def relay(status, body, flavor:)
        Metrics::UPSTREAM_ERRORS.increment(labels: { status: status.to_s, flavor: flavor.to_s })
        case flavor
        when :oai
          [status, JSON_HEADERS.dup, [oai_error_body(body)]]
        when :ant
          msg = safe_error_message(body) || body
          out = JSON.generate({ type: "error", error: { type: ant_error_type(status), message: msg } })
          [status, JSON_HEADERS.dup, [out]]
        end
      end

      private

      def oai_error_body(body)
        JSON.parse(body)
        body
      rescue JSON::ParserError
        JSON.generate({ error: { message: body, type: "upstream_error" } })
      end

      def safe_error_message(body)
        JSON.parse(body).dig("error", "message")
      rescue JSON::ParserError
        nil
      end

      def ant_error_type(status)
        case status
        when 401      then "authentication_error"
        when 403      then "permission_error"
        when 429      then "rate_limit_error"
        when 529      then "overloaded_error"
        when 500..599 then "api_error"
        else               "invalid_request_error"
        end
      end
    end

    # mlx_lm.server emits {"error":"<string>"} — NOT the OAI {"error":{...}} object.
    # This subclass detects the string-error shape and reshapes it before relaying.
    # Proxy-originated errors (502, load-timeout, swap-error) bypass this relay
    # entirely and are generated in App#upstream_error / App#swap_error_response.
    class Mlx < Oai
      def relay(status, body, flavor:)
        error_str = parse_mlx_error_string(body)
        return super unless error_str

        Metrics::UPSTREAM_ERRORS.increment(labels: { status: status.to_s, flavor: flavor.to_s })
        case flavor
        when :oai
          out = JSON.generate({ error: { message: error_str, type: ant_error_type(status) } })
          [status, JSON_HEADERS.dup, [out]]
        when :ant
          out = JSON.generate({ type: "error", error: { type: ant_error_type(status), message: error_str } })
          [status, JSON_HEADERS.dup, [out]]
        end
      end

      private

      def parse_mlx_error_string(body)
        parsed = JSON.parse(body)
        str = parsed["error"]
        str.is_a?(String) ? str : nil
      rescue JSON::ParserError
        nil
      end
    end
  end
end
