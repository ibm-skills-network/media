FactoryBot.define do
  factory :quality, class: "Videos::Quality" do
    external_video_link { "https://example.com/video.mp4" }
    association :transcoding_profile, factory: :transcoding_profile
    status { :pending }
  end
end
