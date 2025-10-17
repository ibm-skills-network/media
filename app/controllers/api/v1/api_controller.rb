module Api
  module V1
    class ApiController < ApplicationController
      rescue_from ActionController::ParameterMissing do |exc|
        error_unprocessable_entity(exc.message)
      end

      rescue_from ActiveRecord::RecordInvalid do |exc|
        error_unprocessable_entity(exc.message)
      end

      rescue_from ActiveRecord::RecordNotFound, with: :error_not_found

      rescue_from Pundit::NotAuthorizedError, with: :error_unauthorized

    protected

    def error_unprocessable_entity(message)
      render json: { error: message, status: 422 }, status: :unprocessable_entity
    end

    def error_unauthorized
      render json: { error: "unauthorized", status: 401 }, status: :unauthorized
    end

    def error_not_found
      render json: { error: "not found", status: 404 }, status: :not_found
    end
    end
  end
end
