module Sync
  class RolesPermissionsSyncJob < BaseSyncJob

    def perform(batch_size = 5000)
      sync_records_to_couchdb(Role.includes(:privileges), 'roles', batch_size) do |model_class|
        model_class.all
      end
    end

    private

    def get_required_columns
      [:uuid, :role, :description, :location_id]
    end

    def prepare_document(role)
      {
        "_id" => generate_document_id(role),
        "uuid" => role.uuid,
        "name" => role.role,
        "description" => role.description,
        "location_id" => role.location_id,
        "privileges" => role.privileges.map do |p|
          {
            "name" => p.privilege
          }
        end
      }
    end

    def generate_document_id(role)
      "role_#{role.role}"
    end
  end
end