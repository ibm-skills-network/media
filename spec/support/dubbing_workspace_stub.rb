# Stubs DubbingWorkspace so pipeline-job specs don't need real Dir.mktmpdir,
# real disk I/O, or real ActiveStorage uploads. The fake yields paths under a
# predictable `/tmp/ws-stub-<prefix>` dir, records every attach call on the
# returned object, and is shareable across `before` blocks.
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

  # Stubs the workspace and yields the FakeWorkspace to the block for assertion
  # purposes. The block runs once per DubbingWorkspace.with call in the SUT.
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
