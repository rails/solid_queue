module JobBuffer
  extend self

  mattr_accessor :values
  self.values = Concurrent::Array.new

  def clear
    values.clear
  end

  def size
    values.size
  end

  def add(value)
    values << value
  end

  def last_value
    values.last
  end

  def include?(value)
    values.include?(value)
  end
end
