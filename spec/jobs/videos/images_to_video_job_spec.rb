require "rails_helper"

RSpec.describe Videos::ImagesToVideoJob, type: :job do
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
          [ "", "", double(success?: true) ]
        end
      end
    end

    it "creates a video from image and audio chunks" do
      described_class.new.perform(task.id, chunks, 1280, 720)

      expect(task.reload.video_file).to be_attached
    end

    it "sets status to success" do
      described_class.new.perform(task.id, chunks, 1280, 720)

      expect(task.reload.status).to eq("success")
    end

    it "records completion time" do
      described_class.new.perform(task.id, chunks, 1280, 720)

      expect(task.reload.completion_time).to be_present
    end

    context "when image download fails" do
      before do
        allow(Faraday).to receive(:get).and_return(
          double(status: 404, body: "Not found")
        )
      end

      it "raises an error and resets status to pending" do
        expect {
          described_class.new.perform(task.id, chunks, 1280, 720)
        }.to raise_error(/Failed to download image/)

        expect(task.reload.status).to eq("pending")
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

      it "raises an error and resets status to pending" do
        expect {
          described_class.new.perform(task.id, chunks, 1280, 720)
        }.to raise_error(/FFmpeg processing failed/)

        expect(task.reload.status).to eq("pending")
      end
    end
  end
end
