module SolidQueue
  VERSION = "1.3.2"

  def self.next_major_version
    Gem::Version.new(VERSION).segments.first + 1
  end
end
