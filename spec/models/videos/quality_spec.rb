require "rails_helper"

RSpec.describe Videos::Quality, type: :model do
  include_context "ffmpeg video api"

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
