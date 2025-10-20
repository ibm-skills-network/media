json.external_video_link @video.external_video_link
json.qualities do
  @video.qualities.each do |q|
    json.set! q.quality do
      json.status q.status
      json.url q.video_file&.url
    end
  end
end
