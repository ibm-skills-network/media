require "rails_helper"

RSpec.describe Videos::EncodeQualityJob, type: :job do
  include_context "ffmpeg video api"

  let(:transcoding_profile) { create(:transcoding_profile, :p720) }
  let(:quality) { create(:quality, external_video_link: "https://example.com/video.mp4", transcoding_profile: transcoding_profile, status: :pending) }

  describe "#perform" do
    context "when quality is already successful" do
      it "returns early without processing" do
        quality.success!

        expect {
          described_class.new.perform(quality.id)
        }.not_to change { quality.reload.status }
      end
    end

    context "when quality is already processing" do
      it "raises an error" do
        quality.processing!

        expect {
          described_class.new.perform(quality.id)
        }.to raise_error("Quality already processing")
      end
    end

    context "when video download fails" do
      before do
        allow_any_instance_of(Videos::Quality).to receive(:download_to_file).and_return(nil)
      end

      it "marks quality as unavailable" do
        described_class.new.perform(quality.id)

        expect(quality.reload.status).to eq("unavailable")
      end
    end

    context "when video quality is lower than requested profile" do
      let(:transcoding_profile) { create(:transcoding_profile, :p1080) }

      it "marks quality as unavailable" do
        described_class.new.perform(quality.id)

        expect(quality.reload.status).to eq("unavailable")
      end
    end

    context "when encoding succeeds" do
      it "sets status to success" do
        described_class.new.perform(quality.id)

        expect(quality.reload.status).to eq("success")
      end

      it "attaches the encoded video file" do
        described_class.new.perform(quality.id)

        expect(quality.reload.video_file).to be_attached
      end
    end

    context "when encoding fails" do
      before do
        allow(Ffmpeg::Video).to receive(:encode_video).and_return({ success: false, error: "Encoding failed" })
      end

      it "raises an error" do
        expect {
          described_class.new.perform(quality.id)
        }.to raise_error("Encoding failed")
      end

      it "sets status back to pending" do
        begin
          described_class.new.perform(quality.id)
        rescue StandardError
          expect(quality.reload.status).to eq("pending")
        end
      end
    end
  end
end
