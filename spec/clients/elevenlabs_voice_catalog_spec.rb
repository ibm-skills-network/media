require "rails_helper"

RSpec.describe ElevenlabsVoiceCatalog do
  describe "#languages" do
    subject(:catalog) { described_class.new }

    before do
      allow(catalog).to receive(:fetch_voices).and_return([])
      allow(catalog).to receive(:fetch_voices).with("es").and_return([
        { voice_id: "v1", name: "Ana", gender: "female", accent: "latin american" },
        { voice_id: "v2", name: "Luis", gender: "male", accent: "latin american" },
        { voice_id: "v3", name: "Pau", gender: "male", accent: "castilian" },
        { voice_id: "v4", name: "Iris", gender: "female", accent: nil }
      ])
    end

    it "lists only languages that have voices" do
      expect(catalog.languages.map { |l| l[:language_code] }).to eq([ "es" ])
    end

    it "returns the language name, code and distinct dialects" do
      expect(catalog.languages.first).to eq(
        language_name: "Spanish",
        language_code: "es",
        dialects: [ "latin american", "castilian" ]
      )
    end
  end
end
