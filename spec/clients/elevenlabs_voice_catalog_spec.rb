require "rails_helper"

RSpec.describe ElevenlabsVoiceCatalog do
  describe "#languages" do
    subject(:catalog) { described_class.new }

    it "lists every preset language without fetching voices" do
      expect(catalog).not_to receive(:fetch_voices)

      codes = catalog.languages.map { |l| l[:language_code] }
      expect(codes).to eq(DubbingTask::LANGUAGE_CODES.values)
    end

    it "returns the language name and code" do
      expect(catalog.languages.first).to eq(
        language_name: "Spanish",
        language_code: "es"
      )
    end
  end

  describe "#dialects" do
    subject(:catalog) { described_class.new }

    before do
      allow(catalog).to receive(:fetch_voices).with("es").and_return([
        { voice_id: "v1", name: "Ana", gender: "female", accent: "latin american" },
        { voice_id: "v2", name: "Luis", gender: "male", accent: "latin american" },
        { voice_id: "v3", name: "Pau", gender: "male", accent: "castilian" },
        { voice_id: "v4", name: "Iris", gender: "female", accent: nil }
      ])
    end

    it "returns the distinct dialects for the given language only" do
      expect(catalog.dialects("es")).to eq([ "latin american", "castilian" ])
    end
  end

  describe "#pool_for" do
    subject(:catalog) { described_class.new }

    before do
      allow(catalog).to receive(:fetch_voices).with("es").and_return([
        { voice_id: "low", gender: "male", accent: "castilian", usage_character_count_1y: 10, cloned_by_count: 1 },
        { voice_id: "high", gender: "male", accent: "castilian", usage_character_count_1y: 5000, cloned_by_count: 3 },
        { voice_id: "mid", gender: "male", accent: "latin american", usage_character_count_1y: 200, cloned_by_count: 9 },
        { voice_id: "unranked", gender: "male", accent: "latin american", usage_character_count_1y: nil, cloned_by_count: nil },
        { voice_id: "woman", gender: "female", accent: "castilian", usage_character_count_1y: 9999, cloned_by_count: 2 }
      ])
    end

    it "returns matching voices ordered by usage" do
      pool = catalog.pool_for(language_code: "es", dialect: "castilian", gender: "man", min_size: 1)

      expect(pool).to eq([ "high", "low" ])
    end

    it "keeps the ranking when the dialect filter is dropped" do
      pool = catalog.pool_for(language_code: "es", dialect: "castilian", gender: "man", min_size: 3)

      expect(pool).to eq([ "high", "mid", "low", "unranked" ])
    end
  end
end
