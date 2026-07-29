FactoryBot.define do
  factory :dubbing_task do
    video_url { "https://example.com/video.mp4" }
    language { "Spanish" }
    dialect { "latin-american" }
    status { "pending" }

    trait :with_audio          do after(:build) { |t| t.audio.attach(io: StringIO.new("pcm"), filename: "audio.wav", content_type: "audio/wav") } end
    trait :with_source_video   do after(:build) { |t| t.source_video.attach(io: StringIO.new("mp4"), filename: "source.mp4", content_type: "video/mp4") } end
    trait :with_vocals         do after(:build) { |t| t.vocals.attach(io: StringIO.new("voc"), filename: "vocals.wav", content_type: "audio/wav") } end
    trait :with_background     do after(:build) { |t| t.background.attach(io: StringIO.new("bg"), filename: "background.wav", content_type: "audio/wav") } end
    trait :with_dubbed_audio   do after(:build) { |t| t.dubbed_audio.attach(io: StringIO.new("dub"), filename: "dubbed.m4a", content_type: "audio/mp4") } end
    trait :with_dubbed_video   do after(:build) { |t| t.dubbed_video.attach(io: StringIO.new("vid"), filename: "dubbed.mp4", content_type: "video/mp4") } end
  end
end
