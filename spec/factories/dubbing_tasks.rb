FactoryBot.define do
  factory :dubbing_task do
    video_url { "https://example.com/video.mp4" }
    language { "Spanish" }
    dialect { "latin-american" }
    status { "pending" }
  end
end
