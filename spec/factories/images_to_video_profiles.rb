FactoryBot.define do
  factory :images_to_video_profile, class: "Videos::ImagesToVideoProfile" do
    label { "vp9" }
    codec { "libvpx-vp9" }
    audio_codec { "libopus" }
    container { "webm" }
    extra_video_options { [ "-cpu-used", "8", "-deadline", "realtime", "-row-mt", "1" ] }

    trait :av1_nvenc do
      label { "av1_nvenc" }
      codec { "av1_nvenc" }
      audio_codec { "aac" }
      container { "mp4" }
      extra_video_options { [] }
    end
  end
end
