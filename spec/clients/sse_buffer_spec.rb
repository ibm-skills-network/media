require "rails_helper"

RSpec.describe SseBuffer do
  subject(:buffer) { described_class.new }

  it "parses LF-delimited events" do
    expect(buffer.feed("data: one\n\ndata: two\n\n")).to eq([ "one", "two" ])
  end

  it "parses CRLF-delimited events (what OpenAI's transcription stream sends)" do
    expect(buffer.feed("data: {\"a\":1}\r\n\r\ndata: [DONE]\r\n\r\n")).to eq([ '{"a":1}', "[DONE]" ])
  end

  it "holds partial events across feeds, including a split delimiter" do
    expect(buffer.feed("data: hel")).to eq([])
    expect(buffer.feed("lo\r\n")).to eq([])
    expect(buffer.feed("\r\ndata: next\n\n")).to eq([ "hello", "next" ])
  end

  it "reassembles multibyte characters split across chunks" do
    bytes = "data: héllo\n\n".b
    expect(buffer.feed(bytes[0...7])).to eq([])
    expect(buffer.feed(bytes[7..])).to eq([ "héllo" ])
  end

  it "joins multi-line data fields with newlines per the SSE spec" do
    expect(buffer.feed("data: line1\ndata: line2\n\n")).to eq([ "line1\nline2" ])
  end

  it "ignores comment and non-data field lines" do
    expect(buffer.feed(": keep-alive\n\nevent: foo\ndata: payload\n\n")).to eq([ "payload" ])
  end

  it "accepts data: without a space" do
    expect(buffer.feed("data:tight\n\n")).to eq([ "tight" ])
  end
end
