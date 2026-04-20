namespace :solid_queue do
  desc "Install Solid Queue"
  task :install do
    Rails::Command.invoke :generate, [ "solid_queue:install" ]
  end

  desc "start solid_queue supervisor to dispatch and process jobs"
  task start: :environment do
    SolidQueue::Supervisor.start
  end

  desc "Validates the recurring jobs config"
  task validate_recurring_config: :environment do
    abort unless SolidQueue::Configuration.new.valid_recurring_config?
  end
end
