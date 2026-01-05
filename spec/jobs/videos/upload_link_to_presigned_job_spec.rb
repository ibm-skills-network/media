require "rails_helper"

RSpec.describe Videos::UploadLinkToPresignedJob, type: :job do
  let(:video_url) { "https://example.com/video.mp4" }
  let(:presigned_url) { "https://s3.example.com/presigned-upload" }

  describe "#perform" do
    let(:download_response) do
      double(
        success?: true,
        status: 200,
        headers: { "content-type" => "video/mp4" }
      )
    end
    let(:upload_response) { double(success?: true, status: 200) }

    before do
      allow(Faraday).to receive(:get).and_return(download_response)
      allow(Faraday).to receive(:put).and_return(upload_response)
    end

    it "enqueues on the default queue" do
      expect(described_class.new.queue_name).to eq("default")
    end

    it "downloads the video and uploads to presigned URL" do
      expect(Faraday).to receive(:get).with(video_url)
      expect(Faraday).to receive(:put).with(presigned_url)

      described_class.new.perform(video_url, presigned_url)
    end

    context "when download fails" do
      let(:download_response) { double(success?: false, status: 500) }

      it "raises an error" do
        expect {
          described_class.new.perform(video_url, presigned_url)
        }.to raise_error(/Download Failed/)
      end
    end

    context "when upload fails" do
      let(:upload_response) { double(success?: false, status: 500, body: "Upload error") }

      it "raises an error" do
        expect {
          described_class.new.perform(video_url, presigned_url)
        }.to raise_error(/Upload Failed/)
      end
    end
  end
end
