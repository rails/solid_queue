namespace :solid_queue do
  desc "Install Solid Queue"
  task :install do
    Rails::Command.invoke :generate, [ "solid_queue:install" ]
  end

  desc "Update Solid Queue"
  task :update do
    Rails::Command.invoke :generate, [ "solid_queue:update" ]
  end

  desc "Start Solid Queue supervisor to dispatch and process jobs"
  task start: :environment do
    SolidQueue::Supervisor.start
  end
end
