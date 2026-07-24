class DubbingTask < ApplicationRecord
  before_create :assign_playback_key

  # Pipeline intermediates, each job downloads what it needs, runs ffmpeg/Python locally,
  # and re-attaches its outputs so the next job (on any worker pod) can find them
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
    "Croatian"   => "hr",
    "English"    => "en"
  }.freeze

  SUPPORTED_LANGUAGES = LANGUAGE_CODES.keys.freeze

  validates :video_url, presence: true
  validates :language, inclusion: { in: SUPPORTED_LANGUAGES }
  validates :dialect, presence: true
  validate :video_url_is_http

  def voice_map
    @voice_map ||= build_voice_map
  end

  def voice_for(speaker)
    voice_map.fetch(speaker) { voice_map.values.first }
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

  # Drops intermediates (and optionally the HLS prefix) so failed runs don't leak PII
  def purge_pipeline_artifacts!(include_hls:)
    INTERMEDIATE_ATTACHMENTS.each do |name|
      attachment = public_send(name)
      attachment.purge if attachment.attached?
    end
    DubbingHlsUploader.purge(self) if include_hls
  end

  private

  def build_voice_map
    catalog = ElevenlabsVoiceCatalog.new
    map = {}
    segments.group_by { |s| s["gender"] || "man" }.each do |gender, gender_segments|
      speakers = gender_segments.map { |s| s["speaker"] }.uniq
      pool = catalog.pool_for(
        language_code: lang_code,
        dialect: dialect.to_s.tr("-", " "),
        gender: gender,
        min_size: speakers.size
      )
      raise "no voices available for dialect=#{dialect} gender=#{gender}" if pool.blank?
      speakers.each_with_index { |speaker, idx| map[speaker] = pool[idx % pool.length] }
    end
    map
  end

  def assign_playback_key
    self.playback_key ||= SecureRandom.urlsafe_base64(16)
  end

  # Block anything ffmpeg's `-i` could read as a non-HTTP protocol (file://, concat:, pipe:, ...)
  def video_url_is_http
    return if video_url.blank?
    uri = URI.parse(video_url)
    return if %w[http https].include?(uri.scheme) && uri.host.present?
    errors.add(:video_url, "must be an http(s) URL")
  rescue URI::InvalidURIError
    errors.add(:video_url, "is not a valid URL")
  end
end
