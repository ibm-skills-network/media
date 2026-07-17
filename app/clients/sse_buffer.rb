# Incremental SSE parser: feed() raw bytes as they arrive, get back the data
# payload of each completed event. Handles CRLF or LF delimiters, events split
# anywhere across chunks, multi-line data fields, and keep-alive comment lines.
class SseBuffer
  def initialize
    @buffer = String.new(encoding: Encoding::BINARY)
  end

  # Appends bytes and returns the payloads of any events they completed
  def feed(chunk)
    @buffer << chunk.b
    payloads = []
    while (boundary = @buffer.match(/\r?\n\r?\n/))
      block = @buffer.slice!(0, boundary.end(0))
      data_lines = block.lines.filter_map do |line|
        line = line.chomp
        line.delete_prefix("data:").lstrip if line.start_with?("data:")
      end
      payloads << data_lines.join("\n").force_encoding(Encoding::UTF_8) unless data_lines.empty?
    end
    payloads
  end
end
