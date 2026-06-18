# frozen_string_literal: true

require 'logger'
require 'securerandom'
require 'digest'

require_relative 'person_service'

module UserService
  AUTHENTICATION_TOKEN_VALIDITY_PERIOD = 168.hours
  LOGGER = Logger.new $stdout
  HSA_ROLES = ["HSA", "Health Surveillance"]

  ALPHABET = ('a'..'z').to_a + ('0'..'9').to_a + ['/']
  CHAR_TO_INT = ALPHABET.each_with_index.to_h
  INT_TO_CHAR = CHAR_TO_INT.invert
  BASE_TIME = Time.now.to_i

  class UserCreateError < StandardError; end
  class UserUpdateError < InvalidParameterError; end

  def self.find_users(role: nil, search_string: nil, username: nil, include_deactivated: false, location_id: nil, location_ids: nil)
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

    # Filter by role if provided
    if role
      query = query.joins(:roles).where(user_roles: { role: role })
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

  def self.create_user(username:, password:, given_name:, family_name:, roles:, programs:, location_id:, villages:, phone:, gender: nil)

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

    Array(roles).each do |rolename|
      role = Role.find_by(role: rolename)
      next if role.blank?

      UserRole.create(role:, user:)

      # For users with HSA roles villages will have to be assigned to them 
      if HSA_ROLES.include?(role.role)
        # Create UserVillage records for each village.
        # Pass the loaded `user` object (not user_id): UserVillage belongs_to
        # :user is required and would otherwise re-query User under its
        # location scope, silently failing for a user at another facility.
        Array(villages).each do |village_id|
          UserVillage.create(
            user:,
            village_id: village_id,
            creator: User.current.id
          )
        end
      end 

    end
    # user programs
    replace_user_programs(user, programs)

    user
  end

  def self.update_username(user, new_username)
    user = user
    user.username = new_username
    user.save
    user
  end

  def self.update_user_villages(user, village_ids)
    new_village_ids = Array(village_ids).map(&:to_i)
    
    current_user_villages = UserVillage.where(user_id: user.user_id)
    
    current_village_ids = current_user_villages.pluck(:village_id)
    
    villages_to_retire = current_user_villages.where(
      village_id: current_village_ids - new_village_ids,
      retired: 0
    )
    
    villages_to_add = new_village_ids - current_village_ids
    
    villages_to_retire.update_all(retired: 1) if villages_to_retire.any?
    
    # Pass the loaded `user` object (not user_id): UserVillage belongs_to :user
    # is required and would otherwise re-query User under its location scope,
    # silently dropping villages for a user at another facility.
    villages_to_add.each do |village_id|
      UserVillage.create(
        user:,
        village_id: village_id,
        creator: User.current.id
      )
    end
  end

  def self.get_user_villages(user, options = {})
    query = UserVillage.includes(:village)
                      .where(user_id: user.user_id)
                      
    # Apply optional filters
    query = query.where(active: true) if options[:active_only]
    query = query.order(created_at: options[:sort_order] || :desc)
    
    if options[:include_metadata]
      query.select('user_villages.*, villages.name as village_name, 
                   villages.population, villages.district')
    else
      query
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("Failed to fetch villages for user #{user.user_id}: #{e.message}")
    raise VillageQueryError, "Unable to fetch villages for user"
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

    user
  end

  def self.new_authentication_token(user)
    token = create_token
    expires = Time.now + AUTHENTICATION_TOKEN_VALIDITY_PERIOD

    user.update_columns(authentication_token: token, token_expiry_time: expires)
    user.authentication_token = token
    user.token_expiry_time = expires
    User.preload_serialization_payload(user)

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

  def self.authenticate_credentials(username, password)
    user = User.unscoped.with_authentication_preloads.find_by(username:)
    return nil unless user

    begin
      Location.current = user.location if user.location_id.present?
    rescue ActiveRecord::RecordNotFound
      Rails.logger.warn "Location #{user.location_id} not found for user #{username}"
      # Fallback to some global property or skip? 
      # For now, we skip setting it if not found to avoid crash
    end
    unless user&.active? && \
           (bart_authenticate(user, password) || \
           new_arch_authenticate(user, password))
      return nil
    end

    user
  rescue StandardError => e
    Rails.logger.error "Error logging in: #{e}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
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

    # auto expire user password
    UserProperty.where(
      user_id: user.id,
      property: 'last_password_reset'
    ).update_all(property_value: 31.days.ago.to_date)

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
    User.exists?(username:)
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
