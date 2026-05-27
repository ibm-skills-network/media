class ElevenlabsVoiceCatalog
    def pool_for(language_code:, dialect:, gender:, min_size:)
        voices = fetch_voices(language_code)
        matched = filter(voices, dialect:, gender:)

        return matched.map { |v| v[:voice_id] } if matched.size >= min_size

        # in case we don't have enough, we drop accent filter
        broadened = filter(voices, dialect: nil, gender: gender)
        broadened.map { |v| v[:voice_id] }
    end

    private

    def filter(voices, dialect:, gender:)
        api_gender = (gender == "man") ? "male" : "female"
        voices.select do |v|
            (dialect.nil? || v[:accent] == dialect) && v[:gender] == api_gender
        end
    end

    def fetch_voices(language_code)
        cached = Rails.cache.read("elevenlabs:voices:#{language_code}")
        return cached if cached

        response = http_client.get("/v1/shared-voices") do |req|
            req.params["language"] = language_code
            req.params["page_size"] = 100
            req.headers["xi-api-key"] = ENV["ELEVENLABS_FREE_API_KEY"]
        end

        unless response.success?
            Rails.logger.warn("ElevenLabs voices fetch failed: #{response.status} #{response.body}")
            return []
        end

        body = JSON.parse(response.body)
        voices = body["voices"].map do |v|
            {
                voice_id: v["voice_id"],
                name: v["name"],
                gender: v["gender"],
                accent: v["accent"]
            }
        end
        Rails.cache.write("elevenlabs:voices:#{language_code}", voices, expires_in: 24.hours)
        voices
    end

    def http_client
        @http_client ||= Faraday.new(url: "https://api.elevenlabs.io")
    end
end
