module SolidQueue
  VERSION = "1.5.1"

  def self.next_major_version
    Gem::Version.new(VERSION).segments.first + 1
  end
end
