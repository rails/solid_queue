namespace :solid_queue do
  desc "Install Solid Queue"
  task :install do
    Rails::Command.invoke :generate, [ "solid_queue:install" ]
  end

  desc "start solid_queue supervisor to dispatch and process jobs"
  task start: :environment do
    SolidQueue::Supervisor.start
  end

  desc "validate the Solid Queue configuration for the current Rails env without starting any process"
  task check: :environment do
    configuration = SolidQueue::Configuration.new(skip_db_checks: true)
    exit 1 unless configuration.check!
  end
end
