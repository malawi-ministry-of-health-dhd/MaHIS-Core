# frozen_string_literal: true

module Api
  module V1
    ##
    # Security questions: a user sets their own three, and a locked-out user
    # answers them to reset a forgotten password.
    #
    # The reset half is unauthenticated by definition, so it is throttled on the
    # submitted username by the same LoginThrottleService that guards login, and
    # it answers identically whether an account is unknown or simply has no
    # questions set - neither should be an account-existence oracle.
    class SecurityQuestionsController < ApplicationController
      skip_before_action :authenticate, only: %i[public_questions verify reset_password]

      UNAVAILABLE_MESSAGE = 'Password reset by security questions is not available for this account.'
      INVALID_ANSWERS_MESSAGE = 'The answers did not match. Please try again.'

      ##
      # The catalogue to choose from, plus which questions the CURRENT user has
      # already set. Answers are never included.
      def index
        render json: {
          questions: SecurityQuestionService.catalogue,
          required: SecurityQuestionService::REQUIRED_ANSWERS,
          configured: SecurityQuestionService.configured?(User.current),
          selected: SecurityQuestionService.questions_for(User.current)
        }, status: :ok
      end

      ##
      # Sets the current user's questions. Deliberately has no user_id: nobody
      # sets anybody else's answers, not even a superuser - they would then be
      # able to reset that person's password.
      def create
        answers = params.permit(answers: %i[question_id answer])[:answers]
        selected = SecurityQuestionService.save!(User.current, answers)

        render json: { message: 'Security questions saved', selected: }, status: :ok
      end

      ##
      # Removes the current user's questions, disabling this reset route for them.
      def destroy
        SecurityQuestionService.clear!(User.current)

        render json: { message: 'Security questions removed' }, status: :ok
      end

      ##
      # Unauthenticated: the questions a locked-out user must answer.
      def public_questions
        username = params[:username].to_s
        LoginThrottleService.check!(username)

        user = find_by_username(username)
        unless user && SecurityQuestionService.configured?(user)
          # Counted so the endpoint cannot be swept for valid usernames.
          LoginThrottleService.record_failure(username, user:)
          return render json: { errors: [UNAVAILABLE_MESSAGE] }, status: :not_found
        end

        render json: { username: user.username, questions: SecurityQuestionService.questions_for(user) }, status: :ok
      end

      ##
      # Unauthenticated: all three answers must be correct. Success returns a
      # single-use token that authorises a password change and nothing else.
      def verify
        username = params[:username].to_s
        LoginThrottleService.check!(username)

        user = find_by_username(username)
        answers = params.permit(answers: %i[question_id answer])[:answers]

        unless user && SecurityQuestionService.verify(user, answers)
          LoginThrottleService.record_failure(username, user:)
          return render json: { errors: [INVALID_ANSWERS_MESSAGE] }, status: :unauthorized
        end

        LoginThrottleService.record_success(username)
        render json: SecurityQuestionService.issue_reset_token!(user), status: :ok
      end

      ##
      # Unauthenticated: spends the token and sets the new password.
      def reset_password
        password = params[:password].to_s
        user = SecurityQuestionService.consume_reset_token!(params[:reset_token])

        unless user
          return render json: { errors: ['This reset link has expired. Please answer your questions again.'] },
                        status: :unauthorized
        end

        return render json: { errors: ['Password must be at least 6 characters in length'] }, status: :bad_request \
          if password.length < 6

        UserService.reset_password_for(user, password)

        render json: { message: 'Password updated. Please log in with your new password.' }, status: :ok
      end

      private

      def find_by_username(username)
        return nil if username.blank?

        User.unscoped.find_by(username: username.strip)
      end
    end
  end
end
