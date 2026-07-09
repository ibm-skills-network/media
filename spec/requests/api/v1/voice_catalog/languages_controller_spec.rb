require "rails_helper"

RSpec.describe Api::V1::VoiceCatalog::LanguagesController, type: :controller do
  include_context "admin"

  describe "GET #index" do
    let(:catalog) do
      [ { language_name: "Spanish", language_code: "es", dialects: [ "latin american", "castilian" ] } ]
    end

    before do
      client = instance_double(ElevenlabsVoiceCatalog, languages: catalog)
      allow(ElevenlabsVoiceCatalog).to receive(:new).and_return(client)
    end

    it "returns the voice catalog as JSON" do
      get :index

      json = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(json).to eq([
        { "language_name" => "Spanish", "language_code" => "es", "dialects" => [ "latin american", "castilian" ] }
      ])
    end
  end
end
