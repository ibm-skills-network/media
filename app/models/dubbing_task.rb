class DubbingTask < ApplicationRecord
  enum :status, {
    pending: "pending",
    processing: "processing",
    success: "success",
    failed: "failed"
  }, default: "pending"

  VOICES = {
    "peninsular" => {
      "man"   => [ "851ejYcv2BoNPjrkw93G", "eEyWolF7iBpMA65GbtAm", "SKjgN71N3MeGl4r2JbRt" ],
      "woman" => [ "AxFLn9byyiDbMn5fmyqu", "Oe0GElYvnDDV5qP1vbE2", "gD1IexrzCvsXPHUuT0s3" ]
    },
    "latin-american" => {
      "man"   => [ "YExhVa4bZONzeingloMX", "t3eeeqhBjrUqcrPvDqUn", "4XUsiqPDK4UACIM2BILe" ],
      "woman" => [ "cIBxLwfshLYhRB9lCXEg", "nTkjq09AuYgsNR8E4sDe", "nbcvT3C2tyOd2OsRAtUf" ]
    }
  }.freeze

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
  validates :dialect, inclusion: { in: VOICES.keys }
  validate :target_language_is_not_source

  def voice_for(speaker)
    gender = segments.find { |s| s["speaker"] == speaker }&.dig("gender") || "man"
    dialect_voices = VOICES[dialect] || VOICES["latin-american"]
    voice_pool = dialect_voices[gender] || dialect_voices["man"]
    speakers_in_gender = segments.select { |s| s["gender"] == gender }
                                 .map { |s| s["speaker"] }
                                 .uniq
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
