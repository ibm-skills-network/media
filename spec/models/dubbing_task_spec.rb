require "rails_helper"

RSpec.describe DubbingTask, type: :model do
  describe "validations" do
    it "is valid with the factory defaults" do
      expect(build(:dubbing_task)).to be_valid
    end

    it "requires video_url" do
      task = build(:dubbing_task, video_url: nil)
      expect(task).not_to be_valid
      expect(task.errors[:video_url]).to include("can't be blank")
    end

    it "rejects languages outside SUPPORTED_LANGUAGES" do
      task = build(:dubbing_task, language: "Klingon")
      expect(task).not_to be_valid
      expect(task.errors[:language]).to be_present
    end

    it "rejects dialects outside the VOICES map" do
      task = build(:dubbing_task, dialect: "martian")
      expect(task).not_to be_valid
      expect(task.errors[:dialect]).to be_present
    end

    it "rejects target languages whose ISO code equals the source language" do
      stub_const("DubbingTask::LANGUAGE_CODES", { "English" => "en" })
      stub_const("DubbingTask::SUPPORTED_LANGUAGES", [ "English" ])

      task = build(:dubbing_task, language: "English")
      expect(task).not_to be_valid
      expect(task.errors[:language].join).to match(/cannot dub to the source/)
    end
  end

  describe "#lang_code" do
    it "returns the ISO-639-1 code for the language" do
      task = build(:dubbing_task, language: "Spanish")
      expect(task.lang_code).to eq("es")
    end

    it "raises KeyError if language is not in the map" do
      task = build(:dubbing_task)
      task.language = "Klingon"
      expect { task.lang_code }.to raise_error(KeyError)
    end
  end

  describe "#voice_for" do
    let(:task) { build(:dubbing_task, dialect: "latin-american") }

    it "picks the first man voice for the first male speaker" do
      task.segments = [ { "speaker" => "SPEAKER_0", "gender" => "man" } ]
      expected = DubbingTask::VOICES["latin-american"]["man"].first
      expect(task.voice_for("SPEAKER_0")).to eq(expected)
    end

    it "assigns distinct voices to distinct same-gender speakers" do
      task.segments = [
        { "speaker" => "SPEAKER_0", "gender" => "man" },
        { "speaker" => "SPEAKER_1", "gender" => "man" }
      ]
      expect(task.voice_for("SPEAKER_0")).not_to eq(task.voice_for("SPEAKER_1"))
    end

    it "picks from the woman pool for a woman speaker" do
      task.segments = [ { "speaker" => "SPEAKER_0", "gender" => "woman" } ]
      expect(task.voice_for("SPEAKER_0")).to eq(DubbingTask::VOICES["latin-american"]["woman"].first)
    end

    it "wraps around the pool when there are more speakers than voices" do
      pool_size = DubbingTask::VOICES["latin-american"]["man"].length
      task.segments = (0..pool_size).map { |i| { "speaker" => "SPEAKER_#{i}", "gender" => "man" } }
      first = task.voice_for("SPEAKER_0")
      wrapping = task.voice_for("SPEAKER_#{pool_size}")
      expect(wrapping).to eq(first)
    end

    it "falls back to 'man' when the speaker has no gender attribute" do
      task.segments = [ { "speaker" => "SPEAKER_0" } ]
      expect(DubbingTask::VOICES["latin-american"]["man"]).to include(task.voice_for("SPEAKER_0"))
    end
  end

  describe "#export_segments" do
    it "returns subtitle_segments when present" do
      task = build(:dubbing_task,
        subtitle_segments: [ { "start" => 0.0, "end" => 1.0, "text" => "sub" } ],
        segments: [ { "start" => 0.0, "end" => 5.0, "text" => "merged" } ]
      )
      expect(task.export_segments.first["text"]).to eq("sub")
    end

    it "falls back to segments when subtitle_segments is empty" do
      task = build(:dubbing_task,
        subtitle_segments: [],
        segments: [ { "start" => 0.0, "end" => 5.0, "text" => "merged" } ]
      )
      expect(task.export_segments.first["text"]).to eq("merged")
    end
  end

  describe "#voice_settings_for" do
    it "returns the matching VOICE_STYLE_PARAMS entry" do
      task = build(:dubbing_task)
      expect(task.voice_settings_for("excited")).to eq(DubbingTask::VOICE_STYLE_PARAMS["excited"])
    end

    it "falls back to neutral for unknown prosody" do
      task = build(:dubbing_task)
      expect(task.voice_settings_for("unknown")).to eq(DubbingTask::VOICE_STYLE_PARAMS["neutral"])
    end
  end
end
