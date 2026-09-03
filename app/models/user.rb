# frozen_string_literal: true

class User < RetirableRecord
  self.table_name = :users
  self.primary_key = :user_id

  include Locatable

  AUTHENTICATION_PRELOADS = %i[location roles].freeze
  SERIALIZATION_PRELOADS = [
    :location,
    :programs,
    # Serialized payloads carry account_expires_on, which lives in user_property.
    :properties,
    { roles: :privileges },
    { person: [:names, { person_attributes: :type }] }
  ].freeze
  SUPERUSER_ROLE_NAMES = ['Superuser', 'Global Superuser', 'District Superuser', 'Facility Superuser'].freeze
  # Canonical superuser hierarchy. Higher number = more authority. This is the single
  # source of truth shared by the controllers that gate sensitive user/role actions.
  SUPERUSER_ROLE_RANK = {
    'facility superuser' => 1,
    'district superuser' => 2,
    'superuser' => 3,
    'global superuser' => 4
  }.freeze

  # Roles only a Global Superuser may ever grant, whatever the rank comparison
  # would otherwise allow.
  GLOBAL_ONLY_ROLE_NAMES = ['Global Superuser', 'District Superuser'].freeze

  audited except: %i[date_changed authentication_token token_expiry_time]

  belongs_to :person, foreign_key: :person_id

  has_many :notification_alert_recipients, class_name: 'NotificationAlertRecipient', foreign_key: :user_id
  has_many :properties, class_name: 'UserProperty', foreign_key: :user_id
  has_many :user_roles, class_name: 'UserRole'
  has_many :roles, through: :user_roles
  has_many :user_programs
  has_many :session_schedule_assignees
  has_many :programs, through: :user_programs # User programs
  has_many :user_villages
  has_many :villages, through: :user_villages
  has_many(:names,
           -> { order('person_name.preferred' => 'DESC') },
           class_name: 'PersonName',
           foreign_key: :person_id,
           dependent: :destroy)

  # Opt-in: when set, as_json nests the user's assigned villages under
  # `location` as a district -> traditional authority -> village tree (see
  # UserService.assigned_areas). Off by default because as_json also serves the
  # user LIST, which honours `paginate=false` - and an HSA covering a whole
  # traditional authority carries several hundred villages, so folding the tree
  # into every row of an unpaginated list would be an unbounded payload.
  # Login sets it (UserService.new_authentication_token) and users#show sets it
  # on request.
  attr_accessor :serialize_assigned_areas

  scope :with_authentication_preloads, -> { includes(*AUTHENTICATION_PRELOADS) }
  scope :with_serialization_preloads, -> { includes(*SERIALIZATION_PRELOADS) }

  default_scope { where(deactivated_on: nil) } if self.respond_to?(:deactivated_on)

  def self.preload_serialization_payload(user)
    ActiveRecord::Associations::Preloader.new(records: [user], associations: SERIALIZATION_PRELOADS).call
    user
  end

  def active?
    deactivated_on.nil?
  end

  # A supervised user - student or intern - is at the facility for a fixed
  # rotation. The set of supervised roles is owned by LoginResponseService, which
  # already uses it to decide who must pick a supervisor at login; deriving it
  # from there keeps one definition of "supervised" in the system.
  def supervised_trainee?
    held_role_names = loaded_role_names || roles.map(&:role)
    (held_role_names & LoginResponseService::SUPERVISION_REQUIREMENTS.keys).any?
  end

  # The LAST DAY the account may be used, held as a user_property rather than a
  # column on users. Absent means the account never expires, which is every
  # non-supervised user.
  #
  # An unreadable stored value is treated as absent, deliberately: a corrupt
  # property must never be what locks somebody out of the system. This mirrors
  # LoginResponseService.password_expired?, which takes the same view.
  def account_expires_on
    raw = account_expiry_property_value
    return nil if raw.blank?

    begin
      Date.parse(raw.to_s)
    rescue ArgumentError, TypeError
      Rails.logger.warn("[AccountExpiry] Unreadable #{UserService::ACCOUNT_EXPIRY_PROPERTY} for user #{user_id}: #{raw.inspect}")
      nil
    end
  end

  # Expires only once the last valid day has passed.
  def account_expired?(as_of = Date.current)
    expires_on = account_expires_on
    expires_on.present? && as_of > expires_on
  end

  def days_until_account_expiry(as_of = Date.current)
    expires_on = account_expires_on
    return nil if expires_on.blank?

    (expires_on - as_of).to_i
  end

  def self.current
    Thread.current['current_user']
  end

  def self.current=(user)
    Thread.current['current_user'] = user
  end

  def current_location
    Location.current
  end

  def global_superuser?
    role_assigned?('Global Superuser')
  end

  def district_superuser?
    role_assigned?('District Superuser')
  end

  def facility_superuser?
    role_assigned?('Facility Superuser')
  end

  def managed_location_ids
    return nil if global_superuser?

    @managed_location_ids ||= begin
      ids = [location_id.to_i]
      ids += district_location_ids if district_superuser?
      ids.compact.uniq
    end
  end

  # Every location in the same district as this user's own facility. A District
  # Superuser manages users across their whole district, so the scope must be the
  # district's facilities — the children of their *own* facility are wards/villages,
  # which is why scoping on `parent_location: location_id` alone locked them to a
  # single facility. Matches how the facility picker lists a district's facilities
  # (GET /locations?district=<county_district>).
  def district_location_ids
    own_location = Location.unscoped.find_by(location_id:)
    return [] if own_location.nil?

    conditions = ['parent_location = :own_id']
    values = { own_id: own_location.location_id }

    if own_location.parent_location.present?
      conditions << '(location_id = :district_id OR parent_location = :district_id)'
      values[:district_id] = own_location.parent_location
    end

    if own_location.county_district.present?
      conditions << 'county_district = :district_name'
      values[:district_name] = own_location.county_district
    end

    Location.where(conditions.join(' OR '), values).pluck(:location_id).map(&:to_i)
  end

  def as_json(options = {})
    json = super(options.merge(
      except: %i[password salt secret_question secret_answer
                 authentication_token token_expiry_time],
      methods: %i[current_location account_expires_on],
      include: {
        roles: { include: { privileges: {} } },
        programs: {},
        location: { only: %i[location_id name] },
        person: {
          include: {
            names: {},
            person_attributes: {
              only: [:person_attribute_type_id, :value, :created_at],
              methods: [:attribute_type_name]
            }
            # addresses: {}
          }
        }
      }
    ))

    # If user is a superuser, ensure they have ALL privileges
    if is_superuser?
      all_privileges = Privilege.pluck(:privilege, :description, :uuid).map do |privilege, description, uuid|
        { privilege:, description:, uuid: }
      end
      json['roles'].each do |role|
        if role['role']&.downcase&.include?('superuser')
          role['privileges'] = all_privileges
        end
      end
    end

    if serialize_assigned_areas
      # Nested under `location` because the assigned areas hang off the facility's
      # own district: a facility and a traditional authority are both children of
      # the district in the location tree. The node is created when the user has
      # no facility so that clients can always read location.assigned_areas.
      json['location'] = (json['location'] || {}).merge('assigned_areas' => UserService.assigned_areas(self))
    end

    json
  end

  def is_superuser?
    role_names = loaded_role_names
    return (role_names & SUPERUSER_ROLE_NAMES).any? if role_names

    user_roles.exists?(role: SUPERUSER_ROLE_NAMES)
  end

  # Highest superuser rank held by this user (0 for a non-superuser). Uses SUPERUSER_ROLE_RANK.
  def superuser_rank
    role_names = loaded_role_names || roles.map(&:role)
    role_names.reduce(0) do |highest_rank, role_name|
      rank = SUPERUSER_ROLE_RANK[role_name.to_s.strip.downcase] || 0
      [highest_rank, rank].max
    end
  end

  # Whether this user may grant the given role. Extracted from
  # UsersController#validate_role_permissions so the rule lives beside the rank
  # table it depends on, and anything needing to present a role list (the user
  # management role filter, for one) applies the same test the write path does.
  def may_assign_role?(role_name)
    return true if global_superuser?

    role_rank = SUPERUSER_ROLE_RANK[role_name.to_s.strip.downcase]
    return true if role_rank.nil? # ordinary (non-superuser) role — anyone may assign it

    # Global Superuser / District Superuser may only ever be granted by a Global Superuser.
    return false if GLOBAL_ONLY_ROLE_NAMES.any? { |name| name.casecmp(role_name.to_s).zero? }

    # No one may grant a role that outranks their own.
    superuser_rank >= role_rank
  end

  # Roles this user may grant, plus any they already hold. Holding a role they
  # cannot grant is normal -- a District Superuser cannot assign that role but
  # should still be able to filter for peers who have it.
  def selectable_role_names(role_names)
    held = (loaded_role_names || roles.map(&:role)).map { |name| name.to_s.strip.downcase }

    role_names.select do |role_name|
      may_assign_role?(role_name) || held.include?(role_name.to_s.strip.downcase)
    end
  end

  def name
    person&.name
  end

  private

  def role_assigned?(role_name)
    role_names = loaded_role_names
    return role_names.include?(role_name) if role_names

    user_roles.exists?(role: role_name)
  end

  def loaded_role_names
    if association(:roles).loaded?
      roles.map(&:role)
    elsif association(:user_roles).loaded?
      user_roles.map(&:role)
    end
  end

  # Read from the preloaded association where there is one: account_expires_on is
  # serialized for every user, and the users list renders a page of them at a
  # time, so querying per user would be a page-sized N+1.
  def account_expiry_property_value
    if association(:properties).loaded?
      properties.find { |property| property.property == UserService::ACCOUNT_EXPIRY_PROPERTY }&.property_value
    else
      UserProperty.where(user_id:, property: UserService::ACCOUNT_EXPIRY_PROPERTY).pick(:property_value)
    end
  end
end
