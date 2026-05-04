require 'uri'

module CouchdbUrl
  module_function

  def base_url(raw_url, include_credentials: true)
    uri = URI.parse(raw_url.to_s)
    path = uri.path.to_s.gsub(%r{/+\z}, '')
    path = '' if path == '/'
    port = explicit_port?(raw_url, uri) ? ":#{uri.port}" : ''
    userinfo = include_credentials ? encoded_userinfo(uri) : ''

    "#{uri.scheme}://#{userinfo}#{uri.host}#{port}#{path}"
  end

  def join(raw_url, *segments, include_credentials: true)
    normalized_segments = segments.flatten.compact.map do |segment|
      segment.to_s.gsub(%r{\A/+|/+\z}, '')
    end.reject(&:empty?)

    ([base_url(raw_url, include_credentials: include_credentials)] + normalized_segments).join('/')
  end

  def credentials(raw_url, fallback_username = nil, fallback_password = nil)
    uri = URI.parse(raw_url.to_s)
    [
      decode_component(uri.user) || fallback_username,
      decode_component(uri.password) || fallback_password
    ]
  end

  def explicit_port?(raw_url, uri = URI.parse(raw_url.to_s))
    authority = raw_url.to_s.sub(%r{\A[a-z][a-z0-9+\-.]*://}i, '').split(%r{[/?#]}, 2).first.to_s
    host_port = authority.sub(/\A.*@/, '')

    host_port.match?(/\]:\d+\z/) || (host_port.include?(':') && uri.port != uri.default_port)
  end

  def encoded_userinfo(uri)
    return '' unless uri.user

    password = uri.password ? ":#{uri.password}" : ''
    "#{uri.user}#{password}@"
  end

  def decode_component(value)
    return nil if value.nil? || value.empty?

    URI.decode_www_form_component(value)
  end
end
