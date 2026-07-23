# Stubs DubbingWorkspace so pipeline specs skip disk I/O and uploads
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
