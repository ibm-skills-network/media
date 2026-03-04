class Setting
  TRANSCODING_PROFILES = Videos::TranscodingProfile.all
  DEFAULT_IMAGE_TO_TASK_PROFILE_ID = Videos::ImagesToVideoProfile.av1_nvenc.pick(:id)
end
