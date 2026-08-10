# frozen_string_literal: true

module Api
  module V1
    class PasskeysController < ApplicationController
      # The passkey ceremony action is called `verify` rather than `authenticate`
      # so it does not shadow ApplicationController#authenticate, which every
      # other action here relies on as its `before_action` auth check. The route
      # still exposes it as /auth/passkeys/authenticate.
      skip_before_action :authenticate, only: %i[register verify]

      def register
        session_token, credential = params.require(%i[session_token credential])
        user = PasskeyAuthenticationService.register(
          session_token:,
          credential: credential.to_unsafe_h,
          nickname: params[:nickname]
        )

        render json: login_response(user, UserService.new_authentication_token(user)), status: :ok
      rescue ActiveRecord::RecordNotFound, WebAuthn::Error => e
        render json: { errors: [e.message] }, status: :unauthorized
      end

      def verify
        session_token, credential = params.require(%i[session_token credential])
        user = PasskeyAuthenticationService.authenticate(
          session_token:,
          credential: credential.to_unsafe_h
        )

        render json: login_response(user, UserService.new_authentication_token(user)), status: :ok
      rescue ActiveRecord::RecordNotFound, WebAuthn::Error => e
        render json: { errors: [e.message] }, status: :unauthorized
      end

      # Devices registered for a user, so a superuser can see what a reset would clear.
      def index
        target = manageable_user(params[:user_id])
        return unless authorise_sensitive_management!(target)

        render json: { devices: PasskeyAuthenticationService.device_summaries(target) }, status: :ok
      end

      # Clears a user's registered passkeys so their next login enrols the device
      # they are on, leaving the extra security layer enabled.
      def reset
        target = manageable_user(params[:user_id])
        return unless authorise_sensitive_management!(target)

        revoked = PasskeyAuthenticationService.revoke_all_credentials!(target)
        record_reset_audit!(target, revoked) if revoked.positive?

        render json: { revoked: }, status: :ok
      end

      private

      def login_response(user, api_key)
        LoginResponseService.build(user, api_key)
      end

      def authorise_sensitive_management!(target_user)
        return true if can_manage_sensitive_user?(target_user)

        render json: { errors: ['You are not authorised to reset passkey login for this user'] },
               status: :unauthorized
        false
      end

      def manageable_user(user_id)
        users = User.includes(:roles)

        if User.current.global_superuser?
          users.unscope(where: :location_id).find(user_id)
        elsif User.current.district_superuser?
          users.unscope(where: :location_id).where(location_id: User.current.managed_location_ids).find(user_id)
        else
          users.find(user_id)
        end
      end

      def can_manage_sensitive_user?(target_user)
        current_rank = User.current&.superuser_rank || 0
        target_rank = target_user&.superuser_rank || 0

        # Equal rank is allowed so this matches the users_controller sensitive-update rule.
        current_rank == User::SUPERUSER_ROLE_RANK['global superuser'] || target_rank.zero? || current_rank >= target_rank
      end

      # Clearing a security control is worth a permanent record, written the same
      # way as the supervision audit in LoginResponseService.
      def record_reset_audit!(target_user, revoked)
        actor = User.current
        next_version = (Audited::Audit
                          .where(auditable_type: 'User', auditable_id: target_user.user_id)
                          .maximum(:version) || 0) + 1

        Audited::Audit.create!(
          auditable_type: 'User',
          auditable_id: target_user.user_id,
          associated_type: 'User',
          associated_id: actor.user_id,
          user_id: actor.user_id,
          username: actor.name,
          action: 'passkey_reset',
          audited_changes: { 'revoked_passkeys' => revoked },
          comment: "#{revoked} passkey device(s) reset for #{target_user.username} by #{actor.name}",
          version: next_version
        )
      end
    end
  end
end
