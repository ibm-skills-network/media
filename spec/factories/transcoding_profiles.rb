FactoryBot.define do
  factory :transcoding_profile, class: "Videos::Quality::TranscodingProfile" do
    label { "720p" }
    width { 1280 }
    height { 720 }
    codec { "h264_nvenc" }
    bitrate_string { "2500k" }
    bitrate_int { 2_500_000 }

    trait :p480 do
      label { "480p" }
      width { 854 }
      height { 480 }
      bitrate_string { "1000k" }
      bitrate_int { 1_000_000 }
    end

    trait :p720 do
      label { "720p" }
      width { 1280 }
      height { 720 }
      bitrate_string { "2500k" }
      bitrate_int { 2_500_000 }
    end

    trait :p1080 do
      label { "1080p" }
      width { 1920 }
      height { 1080 }
      bitrate_string { "5000k" }
      bitrate_int { 5_000_000 }
    end
  end
end
