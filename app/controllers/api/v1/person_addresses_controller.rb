# frozen_string_literal: true

module Api
  module V1
    class PersonAddressesController < ApplicationController
      def create
        address_type = params[:address_type]
        parent_location = params[:parent_location]
        address = params[:addresses_name]

        data = add_address address, address_type, parent_location
        render json: { data: data }
      end

      private

      def add_address(name, address_type, parent_location)
        case address_type
        when 'TA'
          record = TraditionalAuthority.create!(
            name: name,
            district_id: parent_location,
            creator: User.current.id,
            date_created: Time.current
          )
        when 'Village'
          record = Village.create!(
            name: name,
            traditional_authority_id: parent_location,
            creator: User.current.id,
            date_created: Time.current
          )
        else
          raise ArgumentError, "Invalid address_type: #{address_type}"
        end
        
        record
      end
      
    end
  end
end
