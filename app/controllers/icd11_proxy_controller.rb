# frozen_string_literal: true

require 'net/http'
require 'uri'

# Transparent reverse-proxy for the WHO ICD-11 Embedded Coding Tool.
#
# The browser-side coding tool (@whoicd/icd11ect) previously called the ICD-API
# container directly (e.g. http://localhost:6382/icd/release/11/2026-01/mms).
# Routing it through the backend keeps the container off the browser surface and
# centralises its address. Only the public ICD-11 reference API (paths under
# /icd/) is proxied, so this endpoint is intentionally unauthenticated: the coding
# tool cannot attach the MaHIS session token, and no patient data is involved.
#
# Inherits ActionController::API directly (NOT ApplicationController) so the global
# `authenticate` before_action does not apply.
class Icd11ProxyController < ActionController::API
  # Upstream ICD-API container. Override per environment; from the backend host this
  # must be an address that actually reaches the container (e.g. a docker service name).
  UPSTREAM_BASE = ENV.fetch('ICD11_API_URL', 'http://localhost:6382').chomp('/')

  # Headers the ICD-API needs; forwarded from the browser request as-is.
  FORWARDED_HEADERS = %w[Accept Accept-Language Content-Type API-Version].freeze

  def forward
    upstream = URI.parse("#{UPSTREAM_BASE}/icd/#{params[:icd_path]}")
    upstream.query = request.query_string.presence

    upstream_response = Net::HTTP.start(upstream.host, upstream.port, use_ssl: upstream.scheme == 'https') do |http|
      http.request(build_proxy_request(upstream))
    end

    render body: upstream_response.body,
           status: upstream_response.code.to_i,
           content_type: upstream_response['Content-Type'].presence || 'application/json'
  rescue StandardError => e
    Rails.logger.error("[ICD11Proxy] #{e.class}: #{e.message}")
    render json: { error: 'ICD-11 service unavailable' }, status: :bad_gateway
  end

  private

  def build_proxy_request(upstream)
    request_class = request.post? ? Net::HTTP::Post : Net::HTTP::Get
    proxied = request_class.new(upstream)
    FORWARDED_HEADERS.each do |header|
      value = request.headers[header]
      proxied[header] = value if value.present?
    end
    proxied.body = request.raw_post if request.post?
    proxied
  end
end
