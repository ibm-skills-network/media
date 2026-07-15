class ElevenlabsVoiceCatalog
    def languages
        DubbingTask::LANGUAGE_CODES.filter_map do |name, code|
            dialects = dialects_for(fetch_voices(code))
            next if dialects.empty?

            { language_name: name, language_code: code, dialects: dialects }
        end
    end

    def pool_for(language_code:, dialect:, gender:, min_size:)
        voices = fetch_voices(language_code)
        matched = filter(voices, dialect:, gender:)

        return rank(matched).map { |v| v[:voice_id] } if matched.size >= min_size

        # not enough matches, drop the accent filter
        broadened = filter(voices, dialect: nil, gender: gender)
        rank(broadened).map { |v| v[:voice_id] }
    end

    private

    def dialects_for(voices)
        voices.map { |v| v[:accent] }.uniq.reject(&:blank?)
    end

    def rank(voices)
        voices.sort_by { |v| [ -v[:usage_character_count_1y].to_i, -v[:cloned_by_count].to_i ] }
    end

    def filter(voices, dialect:, gender:)
        api_gender = (gender == "man") ? "male" : "female"
        voices.select do |v|
            (dialect.nil? || v[:accent] == dialect) && v[:gender] == api_gender
        end
    end

    def fetch_voices(language_code)
        cached = Rails.cache.read("elevenlabs:voices:v2:#{language_code}")
        return cached if cached

        response = http_client.get("/v1/shared-voices") do |req|
            req.params["language"] = language_code
            req.params["page_size"] = 100
            # default sort is created_date; we want proven voices, not newest uploads
            req.params["sort"] = "usage_character_count_1y"
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
                accent: v["accent"],
                usage_character_count_1y: v["usage_character_count_1y"],
                cloned_by_count: v["cloned_by_count"]
            }
        end
        Rails.cache.write("elevenlabs:voices:v2:#{language_code}", voices, expires_in: 24.hours)
        voices
    end

    def http_client
        @http_client ||= Faraday.new(url: "https://api.elevenlabs.io") do |f|
            # languages() fans out one call per supported language, so a hung
            # connection must not pin the serving request thread
            f.options.timeout = 15
            f.options.open_timeout = 5
        end
    end
end
