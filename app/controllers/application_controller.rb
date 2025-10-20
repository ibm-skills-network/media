class ApplicationController < ActionController::API
  before_action :authenticate_request

  rate_limit to: 100, within: 1.minute, by: -> { request.remote_ip }

  private

  def authenticate_request
    token = extract_bearer_token

    @token_payload = (JWT.decode token, Settings.jwt_secret, true, { algorithm: "HS256" })[0]
  rescue JWT::VerificationError, JWT::DecodeError
    render json: {}, status: :unauthorized
  end

  def extract_bearer_token
    request.headers["Authorization"]&.split(" ")&.last
  end
end
