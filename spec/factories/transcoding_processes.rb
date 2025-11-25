FactoryBot.define do
  factory :transcoding_process, class: "Videos::Quality::TranscodingProcess" do
    association :video
    association :transcoding_profile, factory: :transcoding_profile
    status { :pending }
  end
end
