module JobBuffer
  extend self

  mattr_accessor :values
  self.values = Concurrent::Array.new

  def clear
    values.clear
  end

  def add(value)
    values << value
  end

  def last_value
    values.last
  end
end
