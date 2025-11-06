require "rails_helper"

RSpec.describe Videos::Quality, type: :model do
  include_context "ffmpeg video api"

  describe ".determine_max_quality" do
    it "determines quality from default metadata" do
      file_path = "/path/to/video.mp4"

      quality = described_class.determine_max_quality(file_path)
      expect(quality).to eq("720p")
    end
  end

  describe ".create_qualities_for_video!" do
    let!(:profile_480p) { create(:transcoding_profile, :p480) }
    let!(:profile_720p) { create(:transcoding_profile, :p720) }
    let!(:profile_1080p) { create(:transcoding_profile, :p1080) }

    before do
      # Stub Setting::TRANSCODING_PROFILES to return our test profiles
      stub_const("Setting::TRANSCODING_PROFILES", [ profile_480p, profile_720p, profile_1080p ])
    end

    it "creates a quality for each transcoding profile" do
      expect {
        described_class.create_qualities_for_video!("https://example.com/video.mp4")
      }.to change { Videos::Quality.count }.by(3)
    end

    it "returns an array of created qualities" do
      qualities = described_class.create_qualities_for_video!("https://example.com/video.mp4")

      expect(qualities).to be_an(Array)
      expect(qualities.size).to eq(3)
      expect(qualities).to all(be_a(Videos::Quality))
    end
  end

  describe "#download_to_file" do
    let(:quality) { create(:quality, external_video_link: "https://example.com/video.flv") }

    it "downloads the video and creates a tempfile" do
      temp_file = quality.download_to_file

      expect(temp_file).to be_a(Tempfile)
      expect(temp_file.path).to end_with(".mp4")
      expect(Faraday).to have_received(:get).with(quality.external_video_link)
      expect(temp_file).to be_closed
    end

    it "returns nil for unsupported video formats" do
      allow(Ffmpeg::Video).to receive(:mime_type).with(quality.external_video_link).and_return("video/x-flv")

      expect(quality.download_to_file).to be_nil
    end
  end

  describe "#encode_video" do
    let(:quality) { create(:quality) }

    it "sets status to processing" do
      quality.encode_video

      expect(quality.reload.status).to eq("success")
    end
  end

  describe "#encode_video_later" do
    let(:quality) { create(:quality, status: :processing) }

    it "sets status to pending" do
      quality.encode_video_later

      expect(quality.status).to eq("pending")
    end
  end
end
