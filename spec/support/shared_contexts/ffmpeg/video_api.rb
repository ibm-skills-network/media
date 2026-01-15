RSpec.shared_context "ffmpeg video api" do
  before do
    # Stub Ffmpeg::Video.video_metadata to return realistic metadata
    allow(Ffmpeg::Video).to receive(:video_metadata) do |file_path|
      {
        "streams" => [
          {
            "codec_type" => "video",
            "width" => 1280,
            "height" => 720,
            "bit_rate" => "2500000"
          }
        ],
        "format" => {
          "filename" => file_path,
          "duration" => "60.0"
        }
      }
    end

    # Stub Ffmpeg::Video.video_metadata_from_url
    allow(Ffmpeg::Video).to receive(:video_metadata_from_url) do |url|
      {
        "streams" => [
          {
            "codec_type" => "video",
            "width" => 1280,
            "height" => 720,
            "bit_rate" => "2500000"
          }
        ],
        "format" => {
          "filename" => url,
          "duration" => "60.0"
        }
      }
    end

    # Stub Ffmpeg::Video.mime_type
    allow(Ffmpeg::Video).to receive(:mime_type).and_return("video/mp4")

    # Stub Ffmpeg::Video.cuda_supported?
    allow(Ffmpeg::Video).to receive(:cuda_supported?).and_return({ cuda_supported: true })

    # Stub Faraday.head for mime type checking
    allow(Faraday).to receive(:head) do |url|
      double(headers: { "Content-Type" => "video/mp4" })
    end

    # Stub Faraday.get for video downloads
    allow(Faraday).to receive(:get) do |url, &block|
      request = double(options: double)
      allow(request.options).to receive(:on_data=) do |proc|
        proc.call("video content", 13)
      end
      block.call(request)
    end
  end
end
