class ApplicationController < ActionController::API
  before_action :authenticate_request

  private

  def authenticate_request
    token = extract_bearer_token
    # change this to settings.jwt_secret after settings gem is added from other pr
    @token_payload = (JWT.decode token, ENV.fetch("MEDIA_JWT_SECRET"), true, { algorithm: "HS256" })[0]
  rescue JWT::VerificationError, JWT::DecodeError
    render json: {}, status: :unauthorized
  end

  def extract_bearer_token
    request.headers["Authorization"]&.split(" ")&.last
  end
end
