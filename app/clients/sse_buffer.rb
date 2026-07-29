# Incremental SSE parser, feed raw bytes as they arrive and get back
# completed event payloads, even if an event is split across chunks
class SseBuffer
  def initialize
    @buffer = String.new(encoding: Encoding::BINARY)
  end

  # returns the payloads of any events completed by this chunk
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
