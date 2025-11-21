RSpec.shared_context "admin" do
  let(:auth_headers) do
    token = JWT.encode({ admin: true }, Settings.jwt_secret, "HS256")
    { "Authorization" => "Bearer #{token}" }
  end
end
