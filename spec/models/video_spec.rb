require "rails_helper"

RSpec.describe Video, type: :model do
  include_context "ffmpeg video api"

  describe ".determine_max_quality" do
    it "determines quality from default metadata" do
      file_path = "/path/to/video.mp4"

      quality = described_class.determine_max_quality(file_path)
      expect(quality).to eq("720p")
    end
  end

  describe "#create_qualities!" do
    let(:video) { create(:video) }
    let!(:profile_480p) { create(:transcoding_profile, :p480) }
    let!(:profile_720p) { create(:transcoding_profile, :p720) }
    let!(:profile_1080p) { create(:transcoding_profile, :p1080) }

    before do
      # Stub Setting::TRANSCODING_PROFILES to return our test profiles
      stub_const("Setting::TRANSCODING_PROFILES", [ profile_480p, profile_720p, profile_1080p ])
    end

    it "creates a quality for each transcoding profile" do
      expect {
        video.create_qualities!
      }.to change { video.qualities.count }.by(3)
    end

    it "returns an array of created qualities" do
      qualities = video.create_qualities!

      expect(qualities).to be_an(Array)
      expect(qualities.size).to eq(3)
      expect(qualities).to all(be_a(Videos::Quality))
    end
  end

  describe "#download_to_file" do
    let(:video) { create(:video) }

    it "downloads the video and creates a tempfile" do
      temp_file = video.download_to_file

      expect(temp_file).to be_a(Tempfile)
      expect(temp_file.path).to end_with(".mp4")
      expect(Faraday).to have_received(:get).with(video.external_video_link)
      expect(temp_file).to be_closed
    end

    it "returns nil for unsupported video formats" do
      allow(Ffmpeg::Video).to receive(:mime_type).with(video.external_video_link).and_return("video/x-flv")

      expect(video.download_to_file).to be_nil
    end
  end
end
