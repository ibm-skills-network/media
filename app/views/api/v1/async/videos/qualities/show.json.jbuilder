json.external_video_link @video.external_video_link
json.qualities do
  @video.qualities.includes(:transcoding_profile).each do |q|
    if q.transcoding_profile
      json.set! q.transcoding_profile.label do
        json.status q.status
        json.url q.video_file&.url
      end
    end
  end
end
