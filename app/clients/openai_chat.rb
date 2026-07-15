# Thin wrapper around OpenAI chat completions; returns the message content string.
# `label` prefixes the error so each call site keeps its own failure signature.
module OpenaiChat
  module_function

  def complete(messages:, label:, model: "gpt-5-mini", response_format: nil, timeout: 120)
    conn = Faraday.new do |f|
      f.options.timeout = timeout
      f.options.open_timeout = 10
    end

    body = { model: model, messages: messages }
    body[:response_format] = response_format if response_format

    response = conn.post("https://api.openai.com/v1/chat/completions") do |req|
      req.headers["Authorization"] = "Bearer #{ENV['OPENAI_API_KEY']}"
      req.headers["Content-Type"] = "application/json"
      req.body = body.to_json
    end
    raise "#{label} failed: HTTP #{response.status}" unless response.success?

    JSON.parse(response.body)["choices"][0]["message"]["content"].to_s
  end
end
