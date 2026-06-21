class DubbingTask < ApplicationRecord
  # Pipeline intermediates. Jobs download these, run ffmpeg/Python locally, and re-attach
  # their outputs so the next job — on any worker pod — can pick them up. CleanupJob
  # purges them once HLS is uploaded.
  has_one_attached :audio
  has_one_attached :source_video
  has_one_attached :vocals
  has_one_attached :background
  has_one_attached :dubbed_audio
  has_one_attached :dubbed_video

  INTERMEDIATE_ATTACHMENTS = %i[
    audio
    source_video
    vocals
    background
    dubbed_audio
    dubbed_video
  ].freeze

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
  SOURCE_LANG_NAME = "English".freeze

  LANGUAGE_CODES = {
    "Spanish"    => "es",
    "French"     => "fr",
    "German"     => "de",
    "Italian"    => "it",
    "Portuguese" => "pt",
    "Hindi"      => "hi",
    "Japanese"   => "ja",
    "Chinese"    => "zh",
    "Arabic"     => "ar",
    "Russian"    => "ru",
    "Korean"     => "ko",
    "Dutch"      => "nl",
    "Polish"     => "pl",
    "Turkish"    => "tr",
    "Swedish"    => "sv",
    "Indonesian" => "id",
    "Filipino"   => "fil",
    "Vietnamese" => "vi",
    "Ukrainian"  => "uk",
    "Greek"      => "el",
    "Czech"      => "cs",
    "Romanian"   => "ro",
    "Hungarian"  => "hu",
    "Danish"     => "da",
    "Finnish"    => "fi",
    "Norwegian"  => "no",
    "Malay"      => "ms",
    "Tamil"      => "ta",
    "Bulgarian"  => "bg",
    "Croatian"   => "hr"
  }.freeze

  SUPPORTED_LANGUAGES = LANGUAGE_CODES.keys.freeze

  validates :video_url, presence: true
  validates :language, inclusion: { in: SUPPORTED_LANGUAGES }
  validates :dialect, presence: true
  validate :target_language_is_not_source
  validate :video_url_is_http

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

    raise "no voices available for dialect=#{dialect} gender=#{gender}" if voice_pool.blank?

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

  # Purges intermediates and (optionally) the HLS prefix in COS. Called by CleanupJob on
  # success and by each job's sidekiq_retries_exhausted hook on terminal failure — leaving
  # artifacts behind would leak PII.
  def purge_pipeline_artifacts!(include_hls:)
    INTERMEDIATE_ATTACHMENTS.each do |name|
      attachment = public_send(name)
      attachment.purge if attachment.attached?
    end
    DubbingHlsUploader.purge(id) if include_hls
  end

  private

  def target_language_is_not_source
    return unless language && LANGUAGE_CODES[language] == SOURCE_LANG_CODE
    errors.add(:language, "cannot dub to the source language (#{SOURCE_LANG_CODE})")
  end

  # Reject anything ffmpeg's `-i` might read as a non-HTTP protocol (file://, concat:,
  # pipe:, ...) or an SSRF target with no host.
  def video_url_is_http
    return if video_url.blank?
    uri = URI.parse(video_url)
    return if %w[http https].include?(uri.scheme) && uri.host.present?
    errors.add(:video_url, "must be an http(s) URL")
  rescue URI::InvalidURIError
    errors.add(:video_url, "is not a valid URL")
  end
end
