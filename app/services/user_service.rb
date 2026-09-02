# frozen_string_literal: true

require 'logger'
require 'securerandom'
require 'digest'

require_relative 'person_service'

module UserService
  # 30 days. Kept in sync with the client's offline-login window
  # (MAHIS/src/services/offline_login_store.ts MAX_OFFLINE_AGE_MS): a device may
  # sign in offline for up to 30 days after the last online login, so the token
  # cached in that offline session must stay valid for the same period —
  # otherwise endpoints that opportunistically hit the online API when a
  # connection returns would 401 mid-window. Both are measured from the same
  # login event, so they expire together.
  AUTHENTICATION_TOKEN_VALIDITY_PERIOD = 720.hours
  LOGGER = Logger.new $stdout
  HSA_ROLES = ["HSA", "Health Surveillance"]

  # Default rotation length for a supervised (student or intern) account.
  DEFAULT_ACCOUNT_DURATION_DAYS = 90
  # The account's last valid day, held in user_property alongside the other
  # per-user login state (last_login_time, last_password_updated) rather than as a
  # column on users. Stored as an ISO date string, which is what lets the sweep
  # below compare it directly in SQL.
  ACCOUNT_EXPIRY_PROPERTY = 'account_expires_on'

  ALPHABET = ('a'..'z').to_a + ('0'..'9').to_a + ['/']
  CHAR_TO_INT = ALPHABET.each_with_index.to_h
  INT_TO_CHAR = CHAR_TO_INT.invert
  BASE_TIME = Time.now.to_i

  class UserCreateError < StandardError; end
  class UserUpdateError < InvalidParameterError; end

  def self.find_users(role: nil, roles: nil, search_string: nil, username: nil, include_deactivated: false,
                      location_id: nil, location_ids: nil)
    # Check current user permissions
    is_global_superuser = User.current.global_superuser?
    is_district_superuser = User.current.district_superuser?
  
    # Base query: Handle scoping roles
    query = if is_global_superuser
              User.unscope(where: :location_id).all
            elsif is_district_superuser
              User.unscope(where: :location_id).where(location_id: User.current.managed_location_ids)
            else
              User.where(location_id: User.current.location_id)
            end
  
    # Unscope deactivated_on if requested
    query = query.unscope(where: :deactivated_on) if include_deactivated

    # Filter by role if provided. `roles` matches any of the given roles, so a
    # user holding one of them is included; a user with several selected roles is
    # still returned once thanks to the distinct below.
    selected_roles = Array(roles).reject(&:blank?)
    selected_roles = Array(role).reject(&:blank?) if selected_roles.empty?

    if selected_roles.any?
      query = query.joins(:roles).where(user_roles: { role: selected_roles })
      query = query.distinct if selected_roles.size > 1
    end

    if location_id.present?
      query = query.where(location_id: location_id)
    elsif location_ids.present?
      query = query.where(location_id: Array(location_ids).reject(&:blank?))
    end
  
    # Filter by search_string if provided and not empty
    if search_string.present?
      search_term = "%#{ActiveRecord::Base.sanitize_sql_like(search_string.to_s.strip)}%"
      query = query
              .left_joins(person: :names)
              .where(
                "users.username LIKE :search OR person_name.given_name LIKE :search OR person_name.family_name LIKE :search OR " \
                "CONCAT_WS(' ', person_name.given_name, person_name.family_name) LIKE :search OR " \
                "CONCAT_WS(' ', person_name.family_name, person_name.given_name) LIKE :search",
                search: search_term
              )
              .distinct
    end
  
    # Filter by username if provided and not empty
    if username.present?
      query = query.where("username LIKE ?", "%#{username}%")
    end
  
    count = query.count
    query = query.with_serialization_preloads

    [query, count]
  end

  def self.create_user(username:, password:, given_name:, family_name:, roles:, programs:, location_id:, villages:, phone:, gender: nil,
                       account_duration_days: nil)

    person = person_service.create_person(
      birthdate: nil, birthdate_estimated: false, gender:
    )
    raise UserCreateError, "Person: #{person.errors}" unless person.errors.empty?

    person_service.create_person_name(
      person, given_name:, family_name:
    )

    person_service.create_person_attributes(person, cell_phone_number: phone)

    raise UserCreateError, "Person: #{person.errors}" unless person.errors.empty?

    salt = SecureRandom.base64

    user = User.create(
      username:,
      # WARNING: Consider using bcrypt (not SHA1 or SHA512) for better security
      password: self.hash_password(password, salt),
      salt:,
      person:,
      creator: User.current.id,
      location_id:
    )

    assigned_roles = Array(roles).filter_map { |rolename| Role.find_by(role: rolename) }
    assigned_roles.each { |role| UserRole.create(role:, user:) }

    # Villages are assigned once, outside the role loop: a user holding two HSA
    # roles (e.g. 'HSA' and 'Health Surveillance') previously got a duplicate
    # row for every village, and there is no unique index to stop it.
    if assigned_roles.any? { |role| HSA_ROLES.include?(role.role) }
      update_user_villages(user, villages)
    end
    # user programs
    replace_user_programs(user, programs)

    # Start the 90-day clock. Without this the property is absent, and an absent
    # property reads as "not expired" - so every user created here was exempt
    # from the password policy for life, while users created by the importer
    # (which does set it) were not.
    touch_password_updated!(user)

    apply_account_period!(user, account_duration_days)

    user
  end

  ##
  # Sets (or clears) a supervised user's account period.
  #
  # Only supervised users - students and interns - carry one; for anybody else
  # the column is cleared, so that changing a trainee to a permanent role in the
  # same edit does not leave a stale expiry behind that would later lock them out.
  # Supervised users always end up with a period: an omitted or unusable duration
  # falls back to the default rather than leaving the account open-ended.
  #
  # An existing period is only ever moved when a duration is explicitly supplied
  # - that is the "extend" action. Otherwise editing an unrelated field on a
  # trainee (a phone number, a program) would silently restart their clock and
  # the account would never actually expire.
  def self.apply_account_period!(user, duration_days)
    # Roles were just written through UserRole, so any set cached on this
    # instance is stale and would misclassify the user.
    user.association(:roles).reload

    unless user.supervised_trainee?
      clear_account_period!(user)
      return
    end

    explicit_duration = duration_days.to_s.strip.present?
    return if !explicit_duration && user.account_expires_on.present?

    days = normalize_account_duration_days(duration_days)
    set_account_expiry!(user, Date.current + days)
  end

  ##
  # Writes the account's last valid day. Always ISO-formatted: the nightly sweep
  # compares the stored strings in SQL, which only holds for a fixed format.
  def self.set_account_expiry!(user, expires_on)
    property = UserProperty.find_or_initialize_by(user_id: user.user_id, property: ACCOUNT_EXPIRY_PROPERTY)
    property.user = user
    property.property_value = expires_on.to_date.iso8601
    property.save!
    user.association(:properties).reload if user.association(:properties).loaded?
    expires_on
  end

  def self.clear_account_period!(user)
    UserProperty.where(user_id: user.user_id, property: ACCOUNT_EXPIRY_PROPERTY).delete_all
    user.association(:properties).reload if user.association(:properties).loaded?
  end

  def self.normalize_account_duration_days(duration_days)
    days = duration_days.to_s.strip.to_i
    return DEFAULT_ACCOUNT_DURATION_DAYS unless days.positive?

    days
  end

  ##
  # Records that the user's password is current, starting the expiry window.
  def self.touch_password_updated!(user, at: Time.current)
    property = UserProperty.find_or_initialize_by(
      user_id: user.user_id,
      property: LoginResponseService::PASSWORD_UPDATED_PROPERTY
    )
    property.user = user
    property.property_value = at.iso8601
    property.save!
  end

  ##
  # Backdates the expiry window so the user must set a new password at their
  # next login.
  def self.expire_password!(user)
    touch_password_updated!(user, at: (LoginResponseService::PASSWORD_VALIDITY_PERIOD + 1.day).ago)
  end

  def self.update_username(user, new_username)
    user = user
    user.username = new_username
    user.save
    user
  end

  ##
  # Replaces a user's assigned villages with exactly `village_ids`.
  #
  # Rows are never deleted, only retired and un-retired, so the assignment
  # history stays intact. A village the user has held before therefore already
  # has a row: it has to be REVIVED rather than inserted, which is what the
  # previous implementation missed - it compared the requested ids against all
  # rows including retired ones, so a village that had ever been removed could
  # never be assigned again.
  #
  # Returns the user's active village assignments.
  def self.update_user_villages(user, village_ids)
    requested_ids = Array(village_ids).map(&:to_i).uniq
    existing = UserVillage.where(user_id: user.user_id).index_by { |user_village| user_village.village_id.to_i }

    ActiveRecord::Base.transaction do
      existing.each do |village_id, user_village|
        next if requested_ids.include?(village_id) || retired?(user_village)

        user_village.update!(retired: 1, date_retired: Time.current, retired_by: User.current&.user_id)
      end

      requested_ids.each do |village_id|
        user_village = existing[village_id]

        if user_village.nil?
          # Pass the loaded `user` object (not user_id): UserVillage belongs_to
          # :user is required and would otherwise re-query User under its
          # location scope, silently dropping villages for a user at another
          # facility. create! rather than create so an id that is not a village
          # is reported instead of being dropped without a trace.
          UserVillage.create!(user:, village_id:, creator: User.current&.user_id)
        elsif retired?(user_village)
          user_village.update!(retired: 0, date_retired: nil, retired_by: nil)
        end
      end
    end

    get_user_villages(user).where(retired: 0)
  end

  def self.retired?(user_village)
    user_village.retired.to_i == 1
  end

  def self.get_user_villages(user, options = {})
    UserVillage.includes(:village)
               .where(user_id: user.user_id)
               .order(created_at: options[:sort_order] || :desc)
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("Failed to fetch villages for user #{user.user_id}: #{e.message}")
    raise VillageQueryError, "Unable to fetch villages for user"
  end

  ##
  # A user's assigned villages as a hierarchy, for nesting under their facility:
  # district -> traditional authority -> village.
  #
  # Districts are an ARRAY, not a single node, because nothing constrains a
  # user's villages to their own facility's district - update_user_villages
  # deliberately accepts any village id so a user at one facility can cover
  # areas registered under another. A single district node would silently
  # misreport the first such assignment.
  #
  # Built with raw joins on `location` rather than the Village /
  # TraditionalAuthority models on purpose. Village#traditional_authority
  # overrides its own belongs_to reader with a find_by, so `includes` preloads
  # the association and the reader queries anyway - one query per village, and
  # a village-per-TA count that reaches the high hundreds. This is one query for
  # the whole tree regardless of size.
  def self.assigned_areas(user)
    rows = UserVillage
           .where(user_id: user.user_id, retired: 0)
           .joins('INNER JOIN location village ON village.location_id = user_villages.village_id')
           .joins('LEFT JOIN location traditional_authority ON traditional_authority.location_id = village.parent_location')
           .joins('LEFT JOIN location district ON district.location_id = traditional_authority.parent_location')
           # Retired villages are dropped to match what the Village model would
           # return. The traditional authority and district joins stay unfiltered:
           # they are here to name the village's ancestry, and a retired ancestor
           # must not blank out the name of a village that is still assigned.
           .where(village: { retired: 0 })
           .order(Arel.sql('district.name, traditional_authority.name, village.name'))
           .pluck(Arel.sql(<<~SQL.squish))
             district.location_id, district.name,
             traditional_authority.location_id, traditional_authority.name,
             village.location_id, village.name
           SQL

    rows.group_by { |row| row[0..1] }.map do |(district_id, district_name), district_rows|
      {
        district_id:,
        name: district_name,
        traditional_authorities: district_rows.group_by { |row| row[2..3] }.map do |(ta_id, ta_name), ta_rows|
          {
            traditional_authority_id: ta_id,
            name: ta_name,
            villages: ta_rows.map { |row| { village_id: row[4], name: row[5] } }
          }
        end
      }
    end
  end

  def self.update_user(user, params)
    # Update person name if specified
    if params.include?(:given_name) || params.include?(:family_name) || params.include?(:location_id)
      user_ = user
      name = user.person.names.first
      name.given_name = params[:given_name] if params[:given_name]
      name.family_name = params[:family_name] if params[:family_name]
      user_.location_id = params[:location_id] if params[:location_id]
      name.save
      user_.save
    end

    # Update password if any
    if params[:password]
      user.password = self.hash_password(params[:password], user.salt)
      user.save
    end

    # Update roles if any
    if params[:roles].respond_to?(:each)
      user.user_roles.destroy_all unless params[:must_append_roles]
      params[:roles].each do |rolename|
        role = Role.find rolename
        UserRole.create role:, user:
      end
    end

    # Update programs if any
    replace_user_programs(user, params[:programs]) if params.key?(:programs)

    person_service.update_person_attributes(user.person, cell_phone_number: params[:phone]) if params.key?(:phone)

    # Re-evaluated whenever roles change, so promoting a trainee to a permanent
    # role clears the expiry and moving somebody into a trainee role starts one,
    # without the caller having to remember either.
    if params.key?(:roles) || params.key?(:account_duration_days)
      apply_account_period!(user, params[:account_duration_days])
    end

    user
  end

  def self.new_authentication_token(user)
    token = create_token
    expires = Time.now + AUTHENTICATION_TOKEN_VALIDITY_PERIOD

    user.update_columns(authentication_token: token, token_expiry_time: expires)
    user.authentication_token = token
    user.token_expiry_time = expires
    User.preload_serialization_payload(user)
    # The client caches this payload for offline use, so the login response is
    # where the assigned-area tree has to travel.
    user.serialize_assigned_areas = true

    { token:, expiry_time: expires, user: }
  rescue StandardError => e
    Rails.logger.error "Error creating authentication token: #{e}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
  end

  def self.create_token
    SecureRandom.urlsafe_base64(9)
  end

  def self.set_token(username, token, expiry_time)
    u = User.where(username:).first
    return unless u.present?

    u.authentication_token = token
    u.token_expiry_time    = expiry_time
    u.save
  end

  def self.authenticate(token)
    user = User.unscoped.with_authentication_preloads.find_by(authentication_token: token)
    return nil if user.nil? || user.token_expiry_time < Time.now

    user
  end

  def self.login(username, password)
    user = authenticate_credentials(username, password)
    return nil unless user

    new_authentication_token user
  rescue StandardError => e
    Rails.logger.error "Error logging in: #{e}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
  end

  ##
  # Closes an account whose period has ended, at the moment of login.
  #
  # The deactivation is written rather than merely reported, so the account shows
  # as deactivated in User Management instead of silently failing to log in, and
  # so every other check in the system (User's default_scope, active?) agrees. Any
  # token already issued is cleared too - otherwise a session opened before the
  # expiry date would keep working past it.
  def self.enforce_account_period!(user)
    return unless user&.account_expired?

    expired_on = user.account_expires_on

    if user.active?
      user.deactivated_on = Time.now
      user.authentication_token = nil
      user.token_expiry_time = nil
      user.save(validate: false)
      Rails.logger.info("[AccountExpiry] Deactivated #{user.username} at login; period ended #{expired_on}")
    end

    raise AccountExpiredError.new(expired_on:)
  end

  ##
  # Deactivates every account whose period has already ended. Used by the nightly
  # sweep; the login path enforces the same rule for the account in front of it.
  #
  # Returns the number of accounts closed.
  def self.deactivate_expired_accounts!(as_of = Date.current)
    # Joined and compared in SQL rather than loaded and filtered in Ruby: this runs
    # over every user in the database. ISO dates compare correctly as strings,
    # which is why set_account_expiry! always writes that format.
    expired = User.unscoped
                  .where(deactivated_on: nil)
                  .joins(<<~SQL.squish)
                    INNER JOIN user_property account_period
                            ON account_period.user_id = users.user_id
                           AND account_period.property = #{ActiveRecord::Base.connection.quote(ACCOUNT_EXPIRY_PROPERTY)}
                  SQL
                  .where('account_period.property_value < ?', as_of.to_date.iso8601)

    expired.find_each.count do |user|
      user.update_columns(
        deactivated_on: Time.now,
        authentication_token: nil,
        token_expiry_time: nil
      )
      Rails.logger.info("[AccountExpiry] Swept #{user.username}; period ended #{user.account_expires_on}")
      true
    end
  end

  def self.authenticate_credentials(username, password)
    # Raises TooManyRequestsError before any password comparison when this
    # username is inside a back-off or lock window.
    LoginThrottleService.check!(username)

    user = User.unscoped.with_authentication_preloads.find_by(username:)
    unless user
      # Count unknown usernames too, otherwise the throttle reveals which
      # accounts exist, and spend the same time hashing as a real check would.
      LoginThrottleService.equalize_timing(password)
      LoginThrottleService.record_failure(username)
      return nil
    end

    begin
      Location.current = user.location if user.location_id.present?
    rescue ActiveRecord::RecordNotFound
      Rails.logger.warn "Location #{user.location_id} not found for user #{username}"
      # Fallback to some global property or skip? 
      # For now, we skip setting it if not found to avoid crash
    end
    # The password is checked before the account state so that an expired
    # trainee still gets told why on every attempt, not just the first one that
    # tripped the expiry. Both helpers are pure hash comparisons with no side
    # effects, and a deactivated user still records a throttle failure below, so
    # nothing else about the flow changes.
    password_valid = bart_authenticate(user, password) || new_arch_authenticate(user, password)

    unless password_valid
      LoginThrottleService.record_failure(username, user:)
      return nil
    end

    # Only now that the password is confirmed correct may we say anything about
    # the state of the account - saying it earlier would tell an unauthenticated
    # caller which usernames are real. enforce_account_period! deactivates an
    # expired account and raises, so the login stops here.
    enforce_account_period!(user)

    unless user.active?
      LoginThrottleService.record_failure(username, user:)
      return nil
    end

    LoginThrottleService.record_success(username)
    user
  rescue TooManyRequestsError, AccountExpiredError
    # Expected control flow, not an error to log with a backtrace.
    raise
  rescue StandardError => e
    Rails.logger.error "Error logging in: #{e}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
  end

  ##
  # Sets a new password outside the normal update path - used by the security
  # question reset, where there is no session and no current password to check.
  # Mirrors what update_user does, and refreshes last_password_updated so the
  # 90-day expiry restarts rather than firing again immediately.
  def self.reset_password_for(user, password)
    ActiveRecord::Base.transaction do
      user.password = hash_password(password, user.salt)
      user.save!
      touch_password_updated!(user)
    end

    user
  end

  def self.reset_password(code:)
    secret_key =  YAML.safe_load(File.read('config/application.yml'))['password_reset']['secret_key']

    raise InvalidParameterError, 'Code is required' unless code.present?

    #  {:generated_at=>\"kn/gb/xk/rrds/1800385256\", :expires_at=>1800471656}:Hash
    decrypted = decrypt_from_code(code, secret_key)
    
    values = decrypted[:generated_at].split('/')

    expires = decrypted[:expires_at]

    raise InvalidParameterError, 'Invalid code' unless values.size == 5

    fname, lname, username, location_id = values

    # Check if the code is valid
    raise InvalidParameterError, 'Invalid code, missing attributes' unless [fname, lname, username, location_id].all? { |v| v.present? }
    
    # Check if the location is valid
    raise InvalidParameterError, 'Location in code does not match user' unless Location.current.id.to_i == location_id.to_i


    # Check if the code is expired
    raise InvalidParameterError, 'Code Expired' if Time.now.to_i > expires.to_i

    # Check if the user exists
    # example values: sr/ur/an/1/7003728
    # first and last letters of the first and last name, location_id then expiry time
    user = User.joins(person: :names)
      .where("person_name.given_name LIKE '#{fname[0]}%' AND person_name.given_name LIKE '%#{fname[1]}'")
      .where("person_name.family_name LIKE '#{lname[0]}%' AND person_name.family_name LIKE '%#{lname[1]}'")
      .where("username LIKE '#{username[0]}%' AND username LIKE '%#{username[1]}'").first

    raise NotFoundError, 'User Not Found' unless user

    # Check if the user is active
    raise InvalidParameterError, 'User is not active' unless user.active?

    # Force a password change at the next login. This used to write
    # `last_password_reset`, which nothing reads, with a date 31 days old - short
    # of the 90-day window even if the name had been right. So a code-based reset
    # never actually made anyone change their password.
    expire_password!(user)

    # authenticate the user
    new_authentication_token(user)
  end

  def self.string_to_int(str, max_chars)
    str = str.downcase[0, max_chars].ljust(max_chars, 'a')
    result = 0
    str.chars.each_with_index do |char, i|
      result += (CHAR_TO_INT[char] || 0) * (36 ** (max_chars - 1 - i))
    end
    result
  end

  def self.int_to_string(num, max_chars)
    result = ''
    temp = num
    max_chars.times do |i|
      power = max_chars - 1 - i
      char_idx = (temp / (36 ** power)) % 36
      result += INT_TO_CHAR[char_idx]
      temp -= char_idx * (36 ** power)
    end
    result
  end

  def self.derive_key(secret_key)
    key = Digest::SHA256.hexdigest(secret_key).to_i(16) & 0x3FFFFFFFFFFFF
    key
  end

  def self.decrypt_from_code(received_code, secret_key)
    key = derive_key(secret_key)
    obfuscated = CustomBase62.decode(received_code)
    packed = obfuscated ^ key

    fname = int_to_string(packed >> (26 + 10 + 10 + 10), 2)
    lname = int_to_string((packed >> (26 + 10 + 10)) & 0x3FF, 2)
    username = int_to_string((packed >> (26 + 10)) & 0x3FF, 2)
    location_id = ((packed >> 26) & 0x3FF).to_s
    timestamp = (packed & 0x3FFFFFF)
    timestamp = timestamp - 0x4000000 if timestamp >= 0x2000000
    generation_time = timestamp + (Time.now.to_i + 24 * 60 * 60)
    expiration_time = generation_time + 24 * 60 * 60

    original_data = "#{fname}/#{lname}/#{username}/#{location_id}/#{generation_time}"

    puts "Received Code: #{received_code}"
    puts "Decompressed Data (Generated At): #{original_data}"
    puts "Expiration Time: #{expiration_time} (#{Time.at(expiration_time).strftime('%I:%M %p')})"

    { generated_at: original_data, expires_at: expiration_time }
  rescue StandardError => e
    { error: "Decryption failed: #{e.message}" }
  end

  # Tries to authenticate user using the classical BART mode
  def self.bart_authenticate(user, password)
    Digest::SHA512.hexdigest("#{password}#{user.salt}") == user.password ||
      Digest::SHA1.hexdigest("#{password}#{user.salt}") == user.password ||
      Digest::SHA1.hexdigest("#{user.salt}#{password}") == user.password
  end

  # Tries to authenticate user using the new architecture mode
  #
  # NOTE: It's not been established what this model will be but
  # currently SHA512 is being used it seems, so we going with
  # that.
def self.new_arch_authenticate(user, password)
  self.hash_password(password, user.salt) == user.password
end

  def self.check_user(username)
    # Usernames are global login keys, so check across ALL facilities (unscoped) and
    # case-insensitively — otherwise a name taken at another facility, or differing only
    # in case (e.g. "test" vs "Test"), would wrongly appear available.
    User.unscoped.where('LOWER(username) = ?', username.to_s.downcase).exists?
  end

  def self.user_roles(user)
    user.roles
  end

  def self.activate_user(user)
    user.deactivated_on = nil
    user.save
  end

  def self.deactivate_user(user)
    user.deactivated_on = Time.now
    user.save
  end

  def self.person_service
    PersonService.new
  end

  # check if user is already assigned to a project
  def self.find_user_program(user_id, program_id)
    UserProgram.where(user_id:, program_id:).first
  end

  # Replaces a user's program assignments with the given set, atomically.
  #
  # Wrapping the delete + recreate in a transaction and using +create!+ ensures
  # a validation failure on any program can never silently wipe a user's
  # existing assignments — the whole change rolls back instead. (+belongs_to
  # :program+ is required, and +Program+ is scoped to +retired: 0+, so a stale
  # or retired id would otherwise make the non-bang +create+ a silent no-op
  # after +delete_all+ had already cleared the table.)
  #
  # Resetting the associations afterwards makes a freshly-serialized +user+
  # reflect the database rather than a stale eager-loaded :programs collection
  # (the controller preloads :programs before the update runs).
  #
  # We pass the already-loaded +user+ object (not +user_id+) to +create!+. The
  # required +belongs_to :user+ validation otherwise re-queries User through its
  # default scopes — and User is location-scoped via Locatable
  # (+where(location_id: current_location_id)+). When a superuser edits a user
  # at a different facility, +find_user+ loads them with the location scope
  # removed, but the belongs_to re-query would not, so the user "disappears" and
  # the save fails with "User must exist" (a 422). Handing over the object skips
  # that re-query entirely — the same way UserRole.create already does.
  def self.replace_user_programs(user, programs)
    program_ids = normalize_program_ids(programs)

    ActiveRecord::Base.transaction do
      UserProgram.where(user_id: user.user_id).delete_all
      program_ids.each do |program_id|
        UserProgram.create!(user:, program_id:)
      end
    end

    user.association(:programs).reset
    user.association(:user_programs).reset
    user
  end

  def self.normalize_program_ids(programs)
    Array(programs).filter_map do |program|
      program_id = if program.respond_to?(:to_unsafe_h)
                     program.to_unsafe_h[:program_id] || program.to_unsafe_h['program_id'] ||
                       program.to_unsafe_h[:id] || program.to_unsafe_h['id']
                   elsif program.is_a?(Hash)
                     program[:program_id] || program['program_id'] || program[:id] || program['id']
                   else
                     program
                   end

      program_id = program_id.to_i
      program_id.positive? ? program_id : nil
    end.uniq
  end

  def self.hash_password(password, salt)
    Digest::SHA512.hexdigest("#{password}#{salt}")
  end
end
