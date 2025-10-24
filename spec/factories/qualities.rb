FactoryBot.define do
  factory :quality, class: "Videos::Quality" do
    association :video
    association :transcoding_profile, factory: :transcoding_profile
    status { :pending }
  end
end
