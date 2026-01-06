require "rails_helper"

RSpec.describe Videos::ImagesToVideoJob, type: :job do
  include_context "ffmpeg video api"

  let(:task) { create(:images_to_video_task, status: "pending") }
  let(:chunks) do
    [
      { "image_url" => "https://example.com/image1.png", "audio_url" => "https://example.com/audio1.mp3" },
      { "image_url" => "https://example.com/image2.png", "audio_url" => "https://example.com/audio2.mp3" }
    ]
  end

  describe "#perform" do
    before do
      allow(Faraday).to receive(:get).and_return(
        double(status: 200, body: "fake content")
      )

      allow(Open3).to receive(:capture3) do |*args|
        if args.first == "ffprobe"
          [ "5.0", "", double(success?: true) ]
        else
          temp_file_path = args.last
          File.write(temp_file_path, "fake video content") if temp_file_path.is_a?(String) && temp_file_path.end_with?(".mp4")
          [ "", "", double(success?: true) ]
        end
      end
    end

    it "enqueues on the gpu queue" do
      expect(described_class.new.queue_name).to eq("gpu")
    end

    it "creates a video from image and audio chunks" do
      described_class.new.perform(task.id, chunks)

      expect(task.reload.video_file).to be_attached
    end

    it "sets status to success" do
      described_class.new.perform(task.id, chunks)

      expect(task.reload.status).to eq("success")
    end

    it "enqueues UploadLinkToPresignedJob when presigned_url is provided" do
      expect {
        described_class.new.perform(task.id, chunks, presigned_url: "https://example.com/presigned")
      }.to have_enqueued_job(Videos::UploadLinkToPresignedJob)
    end

    it "does not enqueue UploadLinkToPresignedJob when presigned_url is not provided" do
      expect {
        described_class.new.perform(task.id, chunks)
      }.not_to have_enqueued_job(Videos::UploadLinkToPresignedJob)
    end

    context "when image download fails" do
      before do
        allow(Faraday).to receive(:get).and_return(
          double(status: 404, body: "Not found")
        )
      end

      it "raises an error" do
        expect {
          described_class.new.perform(task.id, chunks)
        }.to raise_error(/Failed to download image/)
      end
    end

    context "when ffmpeg processing fails" do
      before do
        allow(Open3).to receive(:capture3) do |*args|
          if args.first == "ffprobe"
            [ "5.0", "", double(success?: true) ]
          else
            [ "", "FFmpeg error", double(success?: false) ]
          end
        end
      end

      it "raises an error" do
        expect {
          described_class.new.perform(task.id, chunks)
        }.to raise_error(/FFmpeg processing failed/)
      end
    end
  end
end
