require "rails_helper"

RSpec.describe Api::V1::VoiceCatalog::LanguagesController, type: :controller do
  include_context "admin"

  describe "GET #index" do
    let(:catalog) do
      [ { language_name: "Spanish", language_code: "es" } ]
    end

    before do
      client = instance_double(ElevenlabsVoiceCatalog, languages: catalog)
      allow(ElevenlabsVoiceCatalog).to receive(:new).and_return(client)
    end

    it "returns the language list as JSON" do
      get :index

      json = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(json).to eq([
        { "language_name" => "Spanish", "language_code" => "es" }
      ])
    end
  end

  describe "GET #dialects" do
    before do
      client = instance_double(ElevenlabsVoiceCatalog)
      allow(client).to receive(:dialects).with("es").and_return([ "latin american", "castilian" ])
      allow(ElevenlabsVoiceCatalog).to receive(:new).and_return(client)
    end

    it "returns the dialects for the requested language" do
      get :dialects, params: { id: "es" }

      json = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(json).to eq([ "latin american", "castilian" ])
    end
  end
end
