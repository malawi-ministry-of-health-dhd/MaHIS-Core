#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# COHORT VALIDATION TOOL
# =============================================================================
# Compares the cohort produced by mahis_backend against a BHT-EMR-API baseline.
#
# Run as a Rails runner script:
#   rails runner validate_cohort.rb [OPTIONS]
#
# Options (environment variables):
#   QUARTER          Quarter to validate, e.g. "Q1 2026" (default: "Q1 2026")
#   BASELINE_URL     BHT-EMR-API base URL (default: http://localhost:3000)
#   BASELINE_USER    BHT-EMR-API username (default: admin)
#   BASELINE_PASS    BHT-EMR-API password (default: test@123)
#   BASELINE_FILE    Path to a saved baseline JSON file (skips remote fetch)
#   MAHIS_URL        mahis_backend base URL (default: http://localhost:3000)
#   MAHIS_USER       mahis_backend username (default: admin)
#   MAHIS_PASS       mahis_backend password (default: Test@123)
#   SAVE_BASELINE    Path to save the fetched baseline JSON for later reuse
#   TOLERANCE        Allowed absolute difference before flagging (default: 0)
#   OUTPUT_FORMAT    "text" or "csv" (default: "text")
#   REGENERATE          Force regeneration on MaHIS side, "true"/"false" (default: false)
#   REGENERATE_BASELINE Force regeneration on BHT baseline side, "true"/"false" (default: false)
#
# Examples:
#   # Basic run against live BHT-EMR-API (uses cached BHT cohort, regenerates MaHIS)
#   rails runner validate_cohort.rb
#
#   # Use saved baseline, compare Q4 2025
#   QUARTER="Q4 2025" BASELINE_FILE=./baseline_q4_2025.json rails runner validate_cohort.rb
#
#   # Save baseline and compare, output CSV
#   SAVE_BASELINE=./baseline_q1_2026.json OUTPUT_FORMAT=csv rails runner validate_cohort.rb
#
#   # Force regeneration on MaHIS only (normal usage)
#   REGENERATE=true rails runner validate_cohort.rb
#
#   # Force regeneration on BHT baseline (one-off, e.g. after data changes in BHT)
#   REGENERATE_BASELINE=true rails runner validate_cohort.rb
# =============================================================================

require 'net/http'
require 'json'
require 'uri'
require 'digest'

# ─── Configuration ────────────────────────────────────────────────────────────
QUARTER        = ENV.fetch('QUARTER', 'Q4 2025')
BASELINE_URL   = ENV.fetch('BASELINE_URL', 'http://localhost:3001')
BASELINE_USER  = ENV.fetch('BASELINE_USER', 'admin')
BASELINE_PASS  = ENV.fetch('BASELINE_PASS', 'test@1234')
BASELINE_FILE  = ENV['BASELINE_FILE']
SAVE_BASELINE  = ENV['SAVE_BASELINE']
MAHIS_URL      = ENV.fetch('MAHIS_URL', 'http://localhost:3000')
MAHIS_USER     = ENV.fetch('MAHIS_USER', 'admin_1217')
MAHIS_PASS     = ENV.fetch('MAHIS_PASS', 'Test@123')
BASELINE_CLIENT         = ENV.fetch('BASELINE_CLIENT', 'POC')
BASELINE_CLIENT_VERSION = ENV.fetch('BASELINE_CLIENT_VERSION', 'v2026.Q2.R0')
MAHIS_CLIENT            = ENV.fetch('MAHIS_CLIENT', 'mahis')
MAHIS_CLIENT_VERSION    = ENV.fetch('MAHIS_CLIENT_VERSION', '0.0.0')
TOLERANCE             = ENV.fetch('TOLERANCE', '0').to_i
OUTPUT_FORMAT         = ENV.fetch('OUTPUT_FORMAT', 'text').downcase
REGENERATE            = ENV.fetch('REGENERATE', 'false').casecmp?('true')
REGENERATE_BASELINE   = ENV.fetch('REGENERATE_BASELINE', 'false').casecmp?('true')

# Max seconds to wait for a cohort to be generated (it runs as a background job)
MAX_WAIT_SECONDS = 3600
POLL_INTERVAL    = 10
# ─── Password reset fallback ────────────────────────────────────────────────────
# Resets a user's password directly in the DB using SHA512+salt (OpenMRS scheme),
# then retries login. Used when a reseed resets the password hash.
def reset_password_and_retry(base_url, username, password, label:, client:, client_version:)
  print yellow("  Login failed — attempting password reset via DB for '#{username}'... ")
  user = User.find_by(username: username)
  unless user
    puts red("user '#{username}' not found in DB")
    return nil
  end

  user.password = Digest::SHA512.hexdigest("#{password}#{user.salt}")
  user.save!(validate: false)
  puts yellow('reset OK, retrying login...')
  get_token(base_url, username, password, label: label, client: client, client_version: client_version)
rescue StandardError => e
  puts red("FAILED: #{e.message}")
  nil
end

# ─── Colour helpers ───────────────────────────────────────────────────────────
def red(s)    = "\e[31m#{s}\e[0m"
def green(s)  = "\e[32m#{s}\e[0m"
def yellow(s) = "\e[33m#{s}\e[0m"
def cyan(s)   = "\e[36m#{s}\e[0m"
def bold(s)   = "\e[1m#{s}\e[0m"

# ─── HTTP helpers ─────────────────────────────────────────────────────────────
def http_get(url, token, client:, client_version:)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  req['Authorization']  = token
  req['Content-Type']   = 'application/json'
  req['Client']         = client
  req['Client-Version'] = client_version
  Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30) { |h| h.request(req) }
end

def http_post(url, body, client:, client_version:)
  uri = URI(url)
  req = Net::HTTP::Post.new(uri)
  req['Content-Type']   = 'application/json'
  req['Client']         = client
  req['Client-Version'] = client_version
  req.body = body.to_json
  Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30) { |h| h.request(req) }
end

# ─── Authentication ───────────────────────────────────────────────────────────
def get_token(base_url, username, password, label:, client:, client_version:)
  print "  Logging into #{label} (#{base_url}) as '#{username}'... "
  resp = http_post("#{base_url}/api/v1/auth/login", { username: username, password: password },
                   client: client, client_version: client_version)

  body = begin
    JSON.parse(resp.body)
  rescue StandardError
    {}
  end
  token = body.dig('authorization', 'token') || body.dig('token')

  if token
    puts green("OK (token: #{token[0..5]}…)")
    token
  else
    puts red('FAILED')
    puts "  Response: #{resp.code} #{resp.body[0..200]}"
    nil
  end
rescue StandardError => e
  puts red("ERROR: #{e.message}")
  nil
end

# ─── Cohort fetcher ───────────────────────────────────────────────────────────
def fetch_cohort(base_url, token, quarter, label:, client:, client_version:, regenerate: false, username: nil,
                 password: nil)
  encoded_quarter = URI.encode_www_form_component(quarter)
  base_cohort_url = "#{base_url}/api/v1/programs/1/reports/cohort?name=#{encoded_quarter}"
  # Only send regenerate=true on the FIRST request to avoid queuing multiple jobs
  first_request_url = regenerate ? "#{base_cohort_url}&regenerate=true" : base_cohort_url
  poll_url          = base_cohort_url

  print "  Fetching #{label} cohort for '#{quarter}'... "

  start             = Time.now
  first_call        = true
  retried_auth      = false
  # When regenerate=true the server destroys the old Report and queues a fresh
  # Sidekiq job, returning 204 while the job runs.  We must see at least one 204
  # (or 202) before accepting a 200 — otherwise we'd grab the stale cached report
  # that existed before the regenerate request was processed.
  seen_queued       = !regenerate # skip the guard when not regenerating

  loop do
    url  = first_call ? first_request_url : poll_url
    resp = http_get(url, token, client: client, client_version: client_version)
    first_call = false
    body = begin
      JSON.parse(resp.body)
    rescue StandardError
      nil
    end

    if resp.is_a?(Net::HTTPSuccess) && body && !body.key?('errors')
      # The cohort job may still be queued/running – BHT returns null (204) or a progress obj
      if resp.is_a?(Net::HTTPNoContent) || body.nil?
        seen_queued = true
        # Job queued, poll
      elsif body.key?('step') || body.key?('pct')
        seen_queued = true
        # Progress response from cohort_progress endpoint
        pct = body['pct'] || '?'
        print "\r  Fetching #{label} cohort for '#{quarter}'... #{pct}%      "
      elsif seen_queued
        elapsed = (Time.now - start).round(1)
        puts green("OK (#{elapsed}s)")
        return body
      else
        # Got a 200 before seeing a 204 — the server returned a cached (stale)
        # report that predates the regenerate request.  Keep polling until the
        # job is enqueued (204) and completed (fresh 200).
        print "\r  Fetching #{label} cohort for '#{quarter}'... waiting for job to start  "
      end
    elsif resp.is_a?(Net::HTTPNoContent)
      seen_queued = true
      # Job queued, keep polling
    elsif resp.code == '401' && !retried_auth && username && password
      retried_auth = true
      puts yellow("\n  401 Unauthorized — re-authenticating...")
      new_token = get_token(base_url, username, password, label: label, client: client, client_version: client_version)
      new_token ||= reset_password_and_retry(base_url, username, password,
                                             label: label, client: client, client_version: client_version)
      if new_token
        token      = new_token
        first_call = true # resend with regenerate flag on the fresh token
        seen_queued = !regenerate # reset stale-cache guard for the fresh request
        next
      else
        puts red('  Re-authentication failed after 401')
        return nil
      end
    else
      puts red("FAILED (#{resp.code})")
      puts "  Response: #{(resp.body || '')[0..200]}"
      return nil
    end

    elapsed = Time.now - start
    if elapsed > MAX_WAIT_SECONDS
      puts red("TIMEOUT after #{MAX_WAIT_SECONDS}s")
      return nil
    end

    print "\r  Fetching #{label} cohort for '#{quarter}'... waiting (#{elapsed.round}s)  "
    sleep POLL_INTERVAL
  end
rescue StandardError => e
  puts red("ERROR: #{e.message}")
  nil
end

# ─── Extract indicator map {name => value} from a Report JSON ─────────────────
def extract_indicators(report_json)
  return {} unless report_json.is_a?(Hash)

  values_array = report_json['values'] || []
  values_array.each_with_object({}) do |v, map|
    next unless v.is_a?(Hash) && v['name']

    raw = v['contents'] || v['value_text'] || v['value'] || ''
    # Contents may be a JSON array of patient_ids or a plain number
    numeric_value = parse_indicator_value(raw)
    map[v['name']] = { value: numeric_value, raw: raw, label: v['indicator_name'] || v['description'] || v['name'] }
  end
end

def parse_indicator_value(raw)
  return raw.to_i if raw.is_a?(Integer)
  return raw.size if raw.is_a?(Array)

  str = raw.to_s.strip
  return str.to_i if str.match?(/\A-?\d+\z/)

  # JSON array of patient IDs
  parsed = begin
    JSON.parse(str)
  rescue StandardError
    nil
  end
  return parsed.size if parsed.is_a?(Array)

  nil
end

# ─── Quarter → date range ─────────────────────────────────────────────────────
def quarter_dates(quarter_str)
  m = quarter_str.match(/Q(\d)\s+(\d{4})/)
  return [nil, nil] unless m

  q = m[1].to_i
  year = m[2].to_i
  start_month = ((q - 1) * 3) + 1
  end_month   = start_month + 2
  start_date  = Date.new(year, start_month, 1)
  end_date    = Date.new(year, end_month, -1)
  [start_date, end_date]
end

# ─── Generate MaHIS cohort directly via DB (fallback when HTTP fails) ─────────
def generate_mahis_cohort_direct(quarter)
  start_date, end_date = quarter_dates(quarter)
  return nil unless start_date

  puts "  Generating mahis_backend cohort directly via CohortBuilder (#{start_date}..#{end_date})..."

  User.current     = User.find_by(username: MAHIS_USER)
  Location.current = User.current&.location || Location.first

  cohort_struct = ArtService::Reports::CohortStruct.new
  builder       = ArtService::Reports::CohortBuilder.new(outcomes_definition: 'moh')

  begin
    builder.init_temporary_tables(start_date, end_date, nil, force_rebuild: REGENERATE)
    builder.build(cohort_struct, start_date, end_date, nil, force_rebuild: false)
    puts green('  Direct generation OK')

    # Convert CohortStruct to indicator map
    cohort_struct.values.each_with_object({}) do |rv, map|
      map[rv.name.to_s] = {
        value: parse_indicator_value(rv.contents),
        raw: rv.contents.to_s,
        label: rv.indicator_name || rv.name.to_s
      }
    end
  rescue StandardError => e
    puts red("  Direct generation FAILED: #{e.message}")
    Rails.logger.error e.backtrace.join("\n")
    nil
  end
end

# ─── Comparison ───────────────────────────────────────────────────────────────
ComparisonResult = Struct.new(:indicator, :label, :baseline, :mahis, :diff, :status)

def compare(baseline_map, mahis_map)
  all_keys = (baseline_map.keys + mahis_map.keys).uniq.sort
  results  = []

  all_keys.each do |key|
    bl_entry = baseline_map[key]
    mh_entry = mahis_map[key]

    bl_val   = bl_entry&.dig(:value)
    mh_val   = mh_entry&.dig(:value)
    label    = bl_entry&.dig(:label) || mh_entry&.dig(:label) || key

    diff   = bl_val && mh_val ? (mh_val - bl_val).abs : nil
    status = if bl_entry.nil?
               :missing_in_baseline
             elsif mh_entry.nil?
               :missing_in_mahis
             elsif bl_val.nil? || mh_val.nil?
               :non_numeric
             elsif diff <= TOLERANCE
               :match
             else
               :mismatch
             end

    results << ComparisonResult.new(key, label, bl_val, mh_val, diff, status)
  end

  results
end

# ─── Reporting ────────────────────────────────────────────────────────────────
def print_text_report(results, quarter, baseline_label, mahis_label)
  matches          = results.count { |r| r.status == :match }
  mismatches       = results.select { |r| r.status == :mismatch }
  missing_baseline = results.select { |r| r.status == :missing_in_baseline }
  missing_mahis    = results.select { |r| r.status == :missing_in_mahis }
  non_numeric      = results.select { |r| r.status == :non_numeric }

  puts
  puts bold('=' * 78)
  puts bold("  COHORT VALIDATION REPORT — #{quarter}")
  puts bold('=' * 78)
  puts "  Baseline : #{baseline_label}"
  puts "  MaHIS    : #{mahis_label}"
  puts "  Tolerance: ±#{TOLERANCE}"
  puts
  puts "  Total indicators compared : #{results.size}"
  puts "  #{green('Matching')}                 : #{matches}"
  puts "  #{red('Mismatches')}               : #{mismatches.size}"
  puts "  #{yellow('Missing in baseline')}      : #{missing_baseline.size}"
  puts "  #{yellow('Missing in MaHIS')}         : #{missing_mahis.size}"
  puts "  Non-numeric / skipped     : #{non_numeric.size}"
  puts

  if mismatches.any?
    puts bold(red('── MISMATCHES ─────────────────────────────────────────────────────────────'))
    puts format('  %-45s %10s %10s %8s', 'Indicator', baseline_label[0..9], mahis_label[0..9], 'Diff')
    puts '  ' + '-' * 76
    mismatches.sort_by { |r| -r.diff.to_i }.each do |r|
      puts format('  %-45s %10s %10s %8s',
                  "#{r.indicator} (#{r.label[0..20]})",
                  r.baseline.to_s,
                  r.mahis.to_s,
                  red(r.diff.to_s))
    end
    puts
  end

  if missing_mahis.any?
    puts bold(yellow('── MISSING IN MAHIS (present in baseline) ──────────────────────────────────'))
    missing_mahis.each do |r|
      puts "  #{r.indicator.ljust(45)} baseline=#{r.baseline}"
    end
    puts
  end

  if missing_baseline.any?
    puts bold(yellow('── MISSING IN BASELINE (new in MaHIS) ──────────────────────────────────────'))
    missing_baseline.each do |r|
      puts "  #{r.indicator.ljust(45)} mahis=#{r.mahis}"
    end
    puts
  end

  puts bold('=' * 78)
  if mismatches.empty? && missing_mahis.empty?
    puts green('  ✓  ALL INDICATORS MATCH — MaHIS cohort is consistent with baseline')
  else
    puts red('  ✗  DISCREPANCIES FOUND — review mismatches above')
  end
  puts bold('=' * 78)
  puts
end

def print_csv_report(results, quarter)
  puts 'quarter,indicator,label,baseline,mahis,diff,status'
  results.each do |r|
    puts [quarter, r.indicator, "\"#{r.label}\"", r.baseline, r.mahis, r.diff, r.status].join(',')
  end
end

# ─── Main ─────────────────────────────────────────────────────────────────────
puts
puts bold(cyan('╔══════════════════════════════════════════════════════════╗'))
puts bold(cyan('║          MaHIS Cohort Validation Tool                    ║'))
puts bold(cyan('╚══════════════════════════════════════════════════════════╝'))
puts
puts "Quarter   : #{bold(QUARTER)}"
puts "Regenerate MaHIS    : #{REGENERATE}"
puts "Regenerate Baseline : #{REGENERATE_BASELINE}"
puts

# ── Step 1: Get baseline cohort ───────────────────────────────────────────────
baseline_indicators = nil
baseline_label      = nil

if BASELINE_FILE && File.exist?(BASELINE_FILE)
  puts bold("▶ Loading baseline from file: #{BASELINE_FILE}")
  raw = begin
    JSON.parse(File.read(BASELINE_FILE))
  rescue StandardError
    nil
  end
  if raw
    baseline_indicators = extract_indicators(raw)
    baseline_label      = 'BHT-file'
    puts green("  Loaded #{baseline_indicators.size} indicators from file")
  else
    puts red('  Failed to parse baseline file')
  end
else
  puts bold("▶ Fetching baseline from BHT-EMR-API (#{BASELINE_URL})")
  bl_token = get_token(BASELINE_URL, BASELINE_USER, BASELINE_PASS, label: 'BHT-EMR-API',
                                                                   client: BASELINE_CLIENT, client_version: BASELINE_CLIENT_VERSION)
  bl_token ||= reset_password_and_retry(BASELINE_URL, BASELINE_USER, BASELINE_PASS, label: 'BHT-EMR-API',
                                                                                    client: BASELINE_CLIENT, client_version: BASELINE_CLIENT_VERSION)

  if bl_token
    bl_report = fetch_cohort(BASELINE_URL, bl_token, QUARTER, label: 'BHT-EMR-API', regenerate: REGENERATE_BASELINE,
                                                              client: BASELINE_CLIENT, client_version: BASELINE_CLIENT_VERSION,
                                                              username: BASELINE_USER, password: BASELINE_PASS)
    if bl_report
      baseline_indicators = extract_indicators(bl_report)
      baseline_label      = 'BHT-API'
      puts "  Extracted #{baseline_indicators.size} indicators"

      if SAVE_BASELINE
        File.write(SAVE_BASELINE, JSON.pretty_generate(bl_report))
        puts cyan("  Baseline saved to #{SAVE_BASELINE}")
      end
    end
  end

  if baseline_indicators.nil?
    puts yellow('  ⚠  Could not reach BHT-EMR-API — no cached baseline available')
    puts red('  No baseline available. Either:')
    puts red("    1. Ensure BHT-EMR-API is reachable at #{BASELINE_URL}")
    puts red('    2. Or provide BASELINE_FILE=<path_to_saved_json>')
    puts
    exit 1
  end
end

puts

# ── Step 2: Get MaHIS cohort ──────────────────────────────────────────────────
puts bold("▶ Fetching MaHIS cohort (#{MAHIS_URL})")
mahis_indicators = nil
mahis_label      = 'MaHIS'

mh_token = get_token(MAHIS_URL, MAHIS_USER, MAHIS_PASS, label: 'mahis_backend',
                                                        client: MAHIS_CLIENT, client_version: MAHIS_CLIENT_VERSION)
mh_token ||= reset_password_and_retry(MAHIS_URL, MAHIS_USER, MAHIS_PASS, label: 'mahis_backend',
                                                                         client: MAHIS_CLIENT, client_version: MAHIS_CLIENT_VERSION)

if mh_token
  mh_report = fetch_cohort(MAHIS_URL, mh_token, QUARTER, label: 'mahis_backend', regenerate: REGENERATE,
                                                         client: MAHIS_CLIENT, client_version: MAHIS_CLIENT_VERSION,
                                                         username: MAHIS_USER, password: MAHIS_PASS)
  if mh_report
    mahis_indicators = extract_indicators(mh_report)
    puts "  Extracted #{mahis_indicators.size} indicators"
  end
end

# Fallback: generate directly via CohortBuilder
if mahis_indicators.nil?
  puts yellow('  HTTP fetch failed — generating directly via CohortBuilder')
  mahis_indicators = generate_mahis_cohort_direct(QUARTER)
end

if mahis_indicators.nil?
  puts red('  Could not produce MaHIS cohort. Aborting.')
  exit 1
end

puts

# ── Step 3: Compare ───────────────────────────────────────────────────────────
puts bold('▶ Comparing indicators...')
results = compare(baseline_indicators, mahis_indicators)

# ── Step 4: Report ────────────────────────────────────────────────────────────
if OUTPUT_FORMAT == 'csv'
  print_csv_report(results, QUARTER)
else
  print_text_report(results, QUARTER, baseline_label, mahis_label)
end

# Exit non-zero if there are mismatches (useful in CI)
mismatch_count = results.count { |r| r.status == :mismatch }
exit(mismatch_count > 0 ? 1 : 0)
