# frozen_string_literal: true

class User < RetirableRecord
  self.table_name = :users
  self.primary_key = :user_id

  include Locatable

  AUTHENTICATION_PRELOADS = %i[location roles].freeze
  SERIALIZATION_PRELOADS = [
    :location,
    :programs,
    { roles: :privileges },
    { person: [:names, { person_attributes: :type }] }
  ].freeze
  SUPERUSER_ROLE_NAMES = ['Superuser', 'Global Superuser', 'District Superuser', 'Facility Superuser'].freeze

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
      if district_superuser?
        ids += Location.where(parent_location: location_id).pluck(:location_id).map(&:to_i)
      end
      ids.compact.uniq
    end
  end

  def as_json(options = {})
    json = super(options.merge(
      except: %i[password salt secret_question secret_answer
                 authentication_token token_expiry_time],
      methods: %i[current_location],
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

    json
  end

  def is_superuser?
    role_names = loaded_role_names
    return (role_names & SUPERUSER_ROLE_NAMES).any? if role_names

    user_roles.exists?(role: SUPERUSER_ROLE_NAMES)
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
end
