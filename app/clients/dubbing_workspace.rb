class DubbingWorkspace
  def self.with(prefix, &block)
    Dir.mktmpdir("dubbing-#{prefix}-") { |dir| block.call(new(dir)) }
  end

  attr_reader :dir

  def initialize(dir)
    @dir = dir
  end

  # Streams the blob to <dir>/<filename> and returns the local path
  def fetch(attachment, filename)
    path = path(filename)
    File.open(path, "wb") do |f|
      attachment.download { |chunk| f.write(chunk) }
    end
    path
  end

  def path(filename)
    File.join(@dir, File.basename(filename))
  end

  # Block form closes the IO so long-running workers don't leak file descriptors
  def attach(attachment, filename, content_type:)
    File.open(path(filename), "rb") do |io|
      attachment.attach(io: io, filename: File.basename(filename), content_type: content_type)
    end
  end
end
