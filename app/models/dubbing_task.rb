class DubbingTask < ApplicationRecord
  enum :status, {
    pending: "pending",
    processing: "processing",
    success: "success",
    failed: "failed"
  }, default: "pending"

  VOICE_STYLE_PARAMS = {
    "excited"    => { stability: 0.4, similarity_boost: 0.75, style: 0.5 },
    "soft"       => { stability: 0.7, similarity_boost: 0.75, style: 0.3 },
    "expressive" => { stability: 0.4, similarity_boost: 0.75, style: 0.6 },
    "neutral"    => { stability: 0.5, similarity_boost: 0.75, style: 0.0 }
  }.freeze

  SOURCE_LANG_CODE = "en".freeze

  LANGUAGE_CODES = {
    "Spanish" => "es"
  }.freeze

  SUPPORTED_LANGUAGES = LANGUAGE_CODES.keys.freeze

  validates :video_url, presence: true
  validates :language, inclusion: { in: SUPPORTED_LANGUAGES }
  validates :dialect, presence: true
  validate :target_language_is_not_source

  def voice_for(speaker)
    gender = segments.find { |s| s["speaker"] == speaker }&.dig("gender") || "man"
    speakers_in_gender = segments.select { |s| s["gender"] == gender }
                                 .map { |s| s["speaker"] }
                                 .uniq

    voice_pool = ElevenlabsVoiceCatalog.new.pool_for(
      language_code: lang_code,
      dialect: dialect.to_s.tr("-", " "),
      gender: gender,
      min_size: speakers_in_gender.size
    )

    idx = speakers_in_gender.index(speaker) || 0
    voice_pool[idx % voice_pool.length]
  end

  def lang_code
    LANGUAGE_CODES.fetch(language)
  end

  def export_segments
    subtitle_segments.presence || segments
  end

  def voice_settings_for(prosody)
    VOICE_STYLE_PARAMS[prosody] || VOICE_STYLE_PARAMS["neutral"]
  end

  private

  def target_language_is_not_source
    return unless language && LANGUAGE_CODES[language] == SOURCE_LANG_CODE
    errors.add(:language, "cannot dub to the source language (#{SOURCE_LANG_CODE})")
  end
end
