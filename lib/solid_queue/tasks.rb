namespace :solid_queue do
  desc "start solid_queue supervisor to process jobs"
  task work: :environment do
    SolidQueue::Supervisor.start(mode: :work)
  end

  desc "start solid_queue scheduler to enqueue scheduled jobs"
  task schedule: :environment do
    SolidQueue::Supervisor.start(mode: :schedule)
  end
end
