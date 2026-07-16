# Incremental parser for a text/event-stream byte stream: feed() raw chunks as
# they arrive and get back the data payload of each event completed so far.
#
# Tolerates what real streams actually send (captured from OpenAI 2026-07):
# CRLF as well as LF event delimiters, events split anywhere across chunks
# (including mid-delimiter and mid-multibyte-character), multi-line data:
# fields (joined with newlines per the SSE spec), and data: with or without a
# space. Comment lines (": keep-alive") and field lines like "event:" carry no
# payload and are ignored.
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
