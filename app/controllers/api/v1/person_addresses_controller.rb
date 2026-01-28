# frozen_string_literal: true

module Api
  module V1
    class PersonAddressesController < ApplicationController
      def create
        address_type = params[:address_type]
        ta_name = params[:ta_name]
        parent_location = params[:parent_location]
        addresses = params[:addresses]

        if address_type == 'Village'
          
          if addresses.is_a?(Array)
            ta_data = ta_name ? create_ta(ta_name, parent_location) : ""
            ta_id = ta_name ? ta_data.id : parent_location
            data = addresses.is_a?(Array) ? add_multiple_villages(addresses, ta_id) : create_village(addresses, ta_id)
          end

          name = params[:addresses_name]
          ta_id = params[:parent_location]
          data = create_village(name, ta_id)
        end



        if address_type == 'TA'
          ta_data = create_ta(name, parent_location)
        end

        render json: { village_data: data, ta_data: ta_data }
      end

      private

      def add_multiple_villages(villages, ta_id)
        villages.map do |village|
          create_village(village, ta_id)
        end
      end

      def create_ta(name, district_id)
        ActiveRecord::Base.transaction do
          ta = TraditionalAuthority.create!(
            name: name,
            district_id: district_id,
            creator: User.current.id,
            date_created: Time.current
          )
          ta.reload

          LocationTagMap.create!(
            location_id: ta.id,
            location_tag: LocationTag.find_by_name('Traditional Authority')
          )
        rescue StandardError => e
          Rails.logger.error("Error creating traditional authority: #{e.message}")
          raise ActiveRecord::Rollback
        end
      end

      def create_village(name, ta_id)
        ActiveRecord::Base.transaction do
          village = Village.create!(
            name: name,
            traditional_authority_id: ta_id,
            creator: User.current.id,
            date_created: Time.current
          )
          village.reload

          LocationTagMap.create!(
            location_id: village.id,
            location_tag: LocationTag.find_by_name('Village')
          )
        rescue StandardError => e
          Rails.logger.error("Error creating village: #{e.message}")
          raise ActiveRecord::Rollback
        end
      end
    end
  end
end
