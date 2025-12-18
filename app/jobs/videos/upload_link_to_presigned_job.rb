module Videos
  class UploadLinkToPresignedJob < ApplicationJob
    queue_as :default

    def perform(video_url, presigned_url)
      temp_file = Tempfile.new([ "presigned_upload_#{Time.current.to_i}", ".mp4" ], binmode: true)

      begin
        download_response = Faraday.get(video_url) do |req|
          req.options.timeout = 600
          req.options.on_data = Proc.new do |chunk|
            temp_file.write(chunk)
          end
        end

        raise "Download Failed: #{download_response.status}" unless download_response.success?

        temp_file.rewind

        content_type = download_response.headers["content-type"]
        Rails.logger.info("Content Type: #{content_type}")

        upload_response = Faraday.put(presigned_url) do |req|
          req.headers["Content-Type"] = content_type
          req.headers["Content-Length"] = temp_file.size.to_s
          req.body = temp_file
          req.options.timeout = 600
        end

        unless upload_response.success?
          raise "Upload Failed: #{upload_response.status} - #{upload_response.body}"
        end
      ensure
        temp_file.close
        temp_file.unlink
      end
    end
  end
end
