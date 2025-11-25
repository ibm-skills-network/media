require "rails_helper"

RSpec.describe Videos::TranscodeVideoJob, type: :job do
  include_context "ffmpeg video api"

  let(:transcoding_profile) { create(:transcoding_profile, :p720) }
  let(:video) { create(:video, external_video_link: "https://example.com/video.mp4") }
  let!(:transcoding_process) { create(:transcoding_process, video: video, transcoding_profile: transcoding_profile, status: :pending) }

  describe "#perform" do
    context "when all transcoding processes are already successful" do
      it "returns early without processing" do
        transcoding_process.success!

        expect(video).not_to receive(:transcode_video!)

        described_class.new.perform(video.id)
      end
    end

    context "when all transcoding processes are unavailable" do
      it "returns early without processing" do
        transcoding_process.unavailable!

        expect(video).not_to receive(:transcode_video!)

        described_class.new.perform(video.id)
      end
    end

    context "when some transcoding processes are pending" do
      it "calls transcode_video! on the video" do
        expect_any_instance_of(Video).to receive(:transcode_video!)

        described_class.new.perform(video.id)
      end
    end

    context "when transcoding succeeds" do
      before do
        allow_any_instance_of(Video).to receive(:transcode_video!).and_call_original
      end

      it "sets status to success for all transcoding processes" do
        described_class.new.perform(video.id)

        expect(transcoding_process.reload.status).to eq("success")
      end

      it "attaches the transcoded video files" do
        described_class.new.perform(video.id)

        expect(transcoding_process.reload.video_file).to be_attached
      end
    end

    context "when transcoding fails" do
      before do
        allow_any_instance_of(Video).to receive(:transcode_video!).and_raise("FFmpeg encoding failed")
      end

      it "raises an error" do
        expect {
          described_class.new.perform(video.id)
        }.to raise_error("FFmpeg encoding failed")
      end
    end

    context "with multiple transcoding processes" do
      let(:transcoding_profile_1080) { create(:transcoding_profile, :p1080) }
      let!(:transcoding_process_1080) { create(:transcoding_process, video: video, transcoding_profile: transcoding_profile_1080, status: :pending) }

      context "when some are already successful" do
        it "still processes the pending ones" do
          transcoding_process.success!

          expect_any_instance_of(Video).to receive(:transcode_video!)

          described_class.new.perform(video.id)
        end
      end

      context "when all are successful or unavailable" do
        it "returns early without processing" do
          transcoding_process.success!
          transcoding_process_1080.unavailable!

          expect(video).not_to receive(:transcode_video!)

          described_class.new.perform(video.id)
        end
      end
    end
  end
end
