# frozen_string_literal: true
# from the MaHIS-Core (backend) app directory on that server:

# COUNT=100 CSV_OUT=/path/to/MAHIS/load-tests/jmeter/users.csv \
#  bundle exec rake load_test:create_users

# when done:
# COUNT=100 bundle exec rake load_test:deactivate_users

# Create / tear down dedicated load-test user accounts for the JMeter login plan.
#
# Idempotent: re-running skips users that already exist. Safe to run on any
# server that has this backend deployed.
#
#   bundle exec rake 'load_test:create_users[100]'
#
# Options are passed as environment variables:
#   COUNT        number of users (overrides the [n] arg)         default: 50
#   PREFIX       username prefix; users are <prefix>01..<prefix>N default: loadtest
#   PASSWORD     shared password for every account               default: Load@Test2026
#   ROLE         role assigned to each user                      default: Clinician
#   CREATOR      existing username used as creator/context       default: admin
#   LOCATION_ID  location for the users                          default: creator's location
#   CSV_OUT      if set, write a username,password CSV here (for JMeter users.csv)
#
# Examples:
#   bundle exec rake 'load_test:create_users[100]'
#   COUNT=200 ROLE=Clinician CSV_OUT=/path/to/users.csv bundle exec rake load_test:create_users
#   bundle exec rake 'load_test:deactivate_users[100]'   # reversible cleanup
namespace :load_test do
  DEFAULTS = {
    count: 50,
    prefix: 'loadtest',
    password: 'Load@Test2026',
    role: 'Clinician',
    creator: 'admin'
  }.freeze

  desc 'Create N dedicated load-test users (idempotent); optionally export a JMeter CSV'
  task :create_users, [:count] => :environment do |_t, args|
    count    = (ENV['COUNT'] || args[:count] || DEFAULTS[:count]).to_i
    prefix   = ENV['PREFIX']   || DEFAULTS[:prefix]
    password = ENV['PASSWORD'] || DEFAULTS[:password]
    role     = ENV['ROLE']     || DEFAULTS[:role]
    creator_username = ENV['CREATOR'] || DEFAULTS[:creator]
    csv_out  = ENV['CSV_OUT']

    abort "COUNT must be positive (got #{count})" unless count.positive?

    creator = User.unscoped.find_by(username: creator_username)
    abort "Creator user '#{creator_username}' not found (set CREATOR=...)." if creator.nil?
    abort "Role '#{role}' not found (set ROLE=...)." if Role.find_by(role: role).nil?

    User.current     = creator
    location_id      = ENV['LOCATION_ID'] || creator.location_id
    location         = Location.find_by(location_id: location_id)
    abort "Location '#{location_id}' not found (set LOCATION_ID=...)." if location.nil?
    Location.current = location

    puts "Creating up to #{count} '#{prefix}NN' users (role=#{role}, location=#{location_id}, creator=#{creator_username})"

    rows = []
    created = 0
    (1..count).each do |i|
      username = format('%<prefix>s%<n>02d', prefix: prefix, n: i)
      if User.unscoped.find_by(username: username)
        puts "exists:  #{username}"
      else
        ActiveRecord::Base.transaction do
          UserService.create_user(
            username: username,
            password: password,
            given_name: 'Load',
            family_name: 'Tester',
            roles: [role],
            programs: [],
            location_id: location_id,
            villages: [],
            phone: nil,
            gender: 'M'
          )
        end
        created += 1
        puts "created: #{username}"
      end
      rows << [username, password]
    end

    if csv_out
      require 'csv'
      CSV.open(csv_out, 'w') do |csv|
        csv << %w[username password]
        rows.each { |row| csv << row }
      end
      puts "CSV written: #{csv_out} (#{rows.size} users)"
    end

    puts "Done. #{created} new user(s) created; #{rows.size} accounts in the #{prefix}01..#{format('%02d', count)} range."
  end

  desc 'Deactivate load-test users (reversible: sets deactivated_on, blocks login)'
  task :deactivate_users, [:count] => :environment do |_t, args|
    count  = (ENV['COUNT'] || args[:count] || DEFAULTS[:count]).to_i
    prefix = ENV['PREFIX'] || DEFAULTS[:prefix]

    deactivated = 0
    (1..count).each do |i|
      username = format('%<prefix>s%<n>02d', prefix: prefix, n: i)
      user = User.unscoped.find_by(username: username)
      next if user.nil? || !user.deactivated_on.nil?

      user.update_columns(deactivated_on: Time.current) # rubocop:disable Rails/SkipsModelValidations
      deactivated += 1
      puts "deactivated: #{username}"
    end

    puts "Done. Deactivated #{deactivated} user(s). Re-enable by clearing deactivated_on."
  end
end
