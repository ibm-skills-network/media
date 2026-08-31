require "rails_helper"

RSpec.describe Video, type: :model do
  include_context "ffmpeg video api"

  describe "validations" do
    describe "#external_video_link_is_http" do
      it "is valid with an http(s) link regardless of the reported mime type" do
        allow(Ffmpeg::Video).to receive(:mime_type).and_return("binary/octet-stream")

        video = build(:video, external_video_link: "https://example.com/video.m4v")
        expect(video).to be_valid
      end

      it "is invalid with a non-http protocol ffmpeg could read" do
        video = build(:video, external_video_link: "file:///etc/passwd")
        expect(video).not_to be_valid
        expect(video.errors[:base]).to include("external video link must be an http(s) URL")
      end

      it "is invalid with an unparseable URL" do
        video = build(:video, external_video_link: "http://exa mple.com/video.mp4")
        expect(video).not_to be_valid
        expect(video.errors[:base]).to include("external video link is not a valid URL")
      end
    end

    context "with video_file attached" do
      it "is valid regardless of the attachment content type" do
        video = build(:video, external_video_link: nil)
        video.video_file.attach(
          io: StringIO.new("video content"),
          filename: "test.m4v",
          content_type: "binary/octet-stream"
        )
        expect(video).to be_valid
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
