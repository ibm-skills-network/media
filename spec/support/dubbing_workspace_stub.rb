# Stubs DubbingWorkspace so pipeline specs don't need real mktmpdir, disk I/O,
# or AS uploads, fake yields paths under /tmp/ws-stub-<prefix> and records every attach
module DubbingWorkspaceStub
  class FakeWorkspace
    attr_reader :dir, :attached

    def initialize(prefix)
      @dir = "/tmp/ws-stub-#{prefix}"
      @attached = []
    end

    def fetch(_attachment, filename)
      path(filename)
    end

    def path(filename)
      File.join(@dir, File.basename(filename))
    end

    def attach(attachment, filename, content_type:)
      @attached << { attachment: attachment, filename: filename, content_type: content_type }
      attachment
    end
  end

  # Yields the FakeWorkspace once per DubbingWorkspace.with call in the SUT so tests
  # can assert on the captured attach/fetch calls afterward
  def stub_dubbing_workspace
    captured = []
    allow(DubbingWorkspace).to receive(:with) do |prefix, &block|
      ws = FakeWorkspace.new(prefix)
      captured << ws
      block.call(ws)
    end
    captured
  end
end

RSpec.configure do |c|
  c.include DubbingWorkspaceStub, type: :job
end
