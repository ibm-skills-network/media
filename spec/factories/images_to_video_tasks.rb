FactoryBot.define do
  factory :images_to_video_task, class: "Videos::ImagesToVideoTask" do
    status { "pending" }
    association :images_to_video_profile
  end
end
