module Api
  module V1
    module Async
      module Videos
        class DubbingTasksController < ApiController
          before_action :set_dubbing_task, only: %w[show hls]

          HLS_CONTENT_TYPES = {
            ".m3u8"   => "application/vnd.apple.mpegurl",
            ".mp4"    => "video/iso.segment",
            ".m4s"    => "video/iso.segment",
            ".vtt"    => "text/vtt",
            ".webvtt" => "text/vtt",
            ".srt"    => "application/x-subrip",
            ".json"   => "application/json"
          }.freeze

          def show
            render json: {
              status: @dubbing_task.status,
              hls_path: @dubbing_task.hls_path,
              error_message: @dubbing_task.error_message
            }, status: :ok
          end

          def create
            task = DubbingTask.new(dubbing_params)
            if task.save
              DubbingPipeline::ExtractAudioJob.perform_later(task.id)
              render json: { id: task.id, status: task.status }, status: :created
            else
              render json: { errors: task.errors }, status: :unprocessable_entity
            end
          end

          # Proxies HLS files from the private COS bucket so the player can resolve
          # sibling URLs without us opening the bucket up
          def hls
            relative = sanitize_hls_path(params[:path])
            return head :not_found unless relative

            object = ActiveStorage::Blob.service.bucket.object("dubbing/#{@dubbing_task.id}/hls/#{relative}")
            # Check existence here, the streaming Enumerator below runs after this rescue scope
            return head :not_found unless object.exists?

            response.headers["Content-Type"] = HLS_CONTENT_TYPES[File.extname(relative)] || "application/octet-stream"
            response.headers["Cache-Control"] = relative.end_with?(".m3u8") ? "no-cache" : "public, max-age=3600"

            self.response_body = Enumerator.new do |y|
              object.get { |chunk| y << chunk }
            end
          rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
            head :not_found
          end

          private

          def set_dubbing_task
            @dubbing_task = DubbingTask.find(params[:id])
          end

          def dubbing_params
            params.require(:dubbing_task).permit(:video_url, :language, :dialect)
          end

          # Rails' `*path` glob passes "../../etc/passwd" through unchanged, so reject anything
          # that escapes the HLS dir, the uploader only writes whitelisted filenames anyway
          def sanitize_hls_path(raw)
            return nil if raw.blank?
            return nil if raw.include?("..") || raw.start_with?("/")
            return nil unless raw.match?(%r{\A[\w./-]+\z})
            raw
          end
        end
      end
    end
  end
end
