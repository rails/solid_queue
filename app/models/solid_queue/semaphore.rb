class SolidQueue::Semaphore < SolidQueue::Record
  def self.wait_for(identifier, limit)
    if semaphore = find_by(identifier: identifier)
      semaphore.value > 0 && attempt_to_update(identifier)
    else
      attempt_to_create(identifier, limit)
    end
  end

  def self.attempt_to_create(identifier, limit)
    create!(identifier: identifier, value: limit - 1)
    true
  rescue ActiveRecord::RecordNotUnique
    attempt_to_update(identifier)
  end

  def self.attempt_to_update(identifier)
    where(identifier: identifier).where("value > 0").update_all("value = COALESCE(value, 1) - 1") > 0
  end
end
