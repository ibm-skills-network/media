FactoryBot.define do
  factory :images_to_video_task, class: "Videos::ImagesToVideoTask" do
    status { "pending" }
  end
end
