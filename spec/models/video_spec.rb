require "rails_helper"

RSpec.describe Video, type: :model do
  include_context "ffmpeg video api"

  describe "validations" do
    describe "#validate_video" do
      context "with external_video_link" do
        it "is valid with a valid video mime type" do
          video = build(:video, external_video_link: "https://example.com/video.mp4")
          expect(video).to be_valid
        end

        it "is invalid with an invalid video mime type" do
          allow(Ffmpeg::Video).to receive(:mime_type).and_return("text/html")

          video = build(:video, external_video_link: "https://example.com/notavideo.html")
          expect(video).not_to be_valid
          expect(video.errors[:base]).to include("external video link must be a valid video link (mp4, webm, or mov)")
        end
      end

      context "with video_file attached" do
        it "is valid with a valid video content type" do
          video = build(:video, external_video_link: nil)
          video.video_file.attach(
            io: StringIO.new("video content"),
            filename: "test.mp4",
            content_type: "video/mp4"
          )
          expect(video).to be_valid
        end

        it "is invalid with an invalid video content type" do
          video = build(:video, external_video_link: nil)
          video.video_file.attach(
            io: StringIO.new("not a video"),
            filename: "test.txt",
            content_type: "text/plain"
          )
          expect(video).not_to be_valid
          expect(video.errors[:base]).to include("video file must be a valid video file (mp4, webm, or mov)")
        end
      end
    end

    describe "#only_one_video_source" do
      it "is invalid when both external_video_link and video_file are present" do
        video = build(:video, external_video_link: "https://example.com/video.mp4")
        video.video_file.attach(
          io: StringIO.new("video content"),
          filename: "test.mp4",
          content_type: "video/mp4"
        )
        expect(video).not_to be_valid
        expect(video.errors[:base]).to include("only one video source can be provided")
      end
    end
  end
end
