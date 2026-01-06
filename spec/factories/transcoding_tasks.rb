FactoryBot.define do
  factory :transcoding_task, class: "Videos::TranscodingTask" do
    association :video
    association :transcoding_profile, factory: :transcoding_profile
    status { :pending }
  end
end
