# frozen_string_literal: true

module Api
  module V1
    class FacilitiesController < ApplicationController
      include CouchdbSync

      FACILITIES_DB_NAME = 'facilities'
      MAX_COUCHDB_UPDATE_ATTEMPTS = 3

      def index
        filters = params.permit(%i[district name location_id paginate page page_size])
        district, name, location_id = filters.values_at(:district, :name, :location_id)

        facilities = facilities_scope
        facilities = facilities.where(location_id: location_id) if location_id.present?
        facilities = facilities.where('location.name LIKE ?', "%#{name}%") if name.present?

        if district.present?
          facilities = facilities.where(
            'location.city_village LIKE :district OR location.county_district LIKE :district',
            district: "%#{district}%"
          )
        end

        total_count = facilities.distinct.count(:location_id)
        page = (params[:page] || 1).to_i
        page_size = (params[:page_size] || DEFAULT_PAGE_SIZE).to_i
        paginated_data = paginate(facilities.order(:name))

        render json: {
          data: paginated_data,
          count: paginated_data.length,
          total_count: total_count,
          pagination: {
            current_page: params[:paginate] == 'false' ? 1 : page,
            per_page: params[:paginate] == 'false' ? total_count : page_size,
            total_count: total_count,
            total_pages: params[:paginate] == 'false' ? 1 : (total_count / page_size.to_f).ceil
          }
        }, include: {
          location_attributes: {
            only: %i[location_attribute_id attribute_type_id value_reference]
          }
        }
      end

      def dde_activation
        dde_activated = boolean_param(params[:dde_activated])
        return render json: { errors: ['dde_activated must be true or false'] }, status: :bad_request if dde_activated.nil?

        facility = facilities_scope.find_by(location_id: facility_location_id_param)
        return render json: { errors: ['Facility not found'] }, status: :not_found unless facility

        document = update_facility_dde_activation(facility, dde_activated)

        render json: {
          data: document,
          dde_activated: document['dde_activated']
        }
      rescue RestClient::Exception, SocketError, Errno::ECONNREFUSED => e
        Rails.logger.error("Failed to update facility DDE activation in CouchDB: #{e.class}: #{e.message}")
        render json: { errors: ['Unable to update DDE activation in CouchDB'] }, status: :bad_gateway
      end

      def districts
        districts = facilities_scope
                    .includes(:parent)
                    .map do |facility|
                      district_name = facility.parent&.name || facility.city_village || facility.county_district
                      next if district_name.blank?

                      {
                        district_id: facility.parent&.location_id,
                        name: district_name
                      }
                    end
                    .compact
                    .uniq { |item| [item[:district_id], item[:name]] }
                    .sort_by { |item| item[:name] }

        render json: {
          data: districts,
          count: districts.length,
          total_count: districts.length
        }
      end

      def nearby
        facility = facilities_scope.find_by(location_id: params[:id])
        return render json: { error: 'Facility not found' }, status: :not_found unless facility

        radius_km = params[:radius_km].presence || 10
        nearby_facilities = facility.nearby_facilities(radius_km.to_f)

        render json: nearby_facilities, include: {
          location_attributes: {
            only: %i[location_attribute_id attribute_type_id value_reference]
          }
        }
      end

      private

      def boolean_param(value)
        return value if value == true || value == false

        case value.to_s.strip.downcase
        when 'true', '1', 'yes', 'y'
          true
        when 'false', '0', 'no', 'n'
          false
        end
      end

      def facility_location_id_param
        params[:id].to_s.sub(/\Afacility_/, '')
      end

      def update_facility_dde_activation(facility, dde_activated)
        ensure_db_exists(FACILITIES_DB_NAME)

        attempts = 0
        begin
          attempts += 1
          existing_document = fetch_facility_couchdb_document(facility)
          document = build_facility_couchdb_document(facility, existing_document, dde_activated)
          response = RestClient.put(
            facility_couchdb_document_url(document['_id']),
            document.to_json,
            { content_type: :json, accept: :json }
          )
          document.merge('_rev' => JSON.parse(response.body)['rev'])
        rescue RestClient::Conflict
          raise if attempts >= MAX_COUCHDB_UPDATE_ATTEMPTS

          retry
        end
      end

      def fetch_facility_couchdb_document(facility)
        response = RestClient.get(facility_couchdb_document_url(facility_document_id(facility)))
        JSON.parse(response.body)
      rescue RestClient::NotFound
        {}
      end

      def build_facility_couchdb_document(facility, existing_document, dde_activated)
        existing_document
          .except('_conflicts')
          .merge(
            '_id' => facility_document_id(facility),
            'location_id' => facility.location_id,
            'name' => facility.name,
            'district' => facility.city_village,
            'latitude' => facility.latitude,
            'longitude' => facility.longitude,
            'dde_activated' => dde_activated
          )
      end

      def facility_document_id(facility)
        "facility_#{facility.location_id}"
      end

      def facility_couchdb_document_url(document_id)
        couchdb_url(FACILITIES_DB_NAME, URI.encode_www_form_component(document_id.to_s))
      end

      def facilities_scope
        Location.includes(:parent, :location_attributes)
                .where(retired: false)
                .where(parent_location: District.select(:location_id))
                .where.not(name: [nil, ''])
                .where.not(city_village: [nil, ''])
                .distinct
      end
    end
  end
end
