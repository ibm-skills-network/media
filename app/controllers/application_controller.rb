class ApplicationController < ActionController::API
  before_action :authenticate_request

  rate_limit to: 1200, within: 1.minute, by: -> { request.remote_ip }

  private

  def authenticate_request
    return if Rails.env.development?

    token = extract_bearer_token

    @token_payload = (JWT.decode token, Settings.jwt_secret, true, { algorithm: "HS256" })[0]
    raise "Unauthorized" unless @token_payload["admin"]
  rescue JWT::VerificationError, JWT::DecodeError, RuntimeError
    render json: {}, status: :unauthorized
  end

  def extract_bearer_token
    request.headers["Authorization"]&.split(" ")&.last
  end
end
