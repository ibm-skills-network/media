class Setting
  TRANSCODING_PROFILES = Videos::TranscodingProfile.all
  DEFAULT_IMAGE_TO_TASK_PROFILE_CODEC = Videos::ImagesToVideoProfile.find_by!(codec: "av1_nvenc").codec
end
