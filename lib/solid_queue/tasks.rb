namespace :solid_queue do
  desc "start solid_queue supervisor"
  task start: :environment do
    SolidQueue::Supervisor.start
  end
end
