namespace :solid_queue do
  desc "start solid_queue supervisor to dispatch and process jobs"
  task start: :environment do
    SolidQueue::Supervisor.start(mode: :all)
  end

  desc "start solid_queue supervisor to process jobs"
  task work: :environment do
    SolidQueue::Supervisor.start(mode: :work)
  end

  desc "start solid_queue dispatcher to enqueue scheduled jobs"
  task dispatch: :environment do
    SolidQueue::Supervisor.start(mode: :dispatch)
  end
end
