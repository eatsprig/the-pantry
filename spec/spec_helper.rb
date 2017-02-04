$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)

require "database_cleaner"
require "active_record"
require "redis"
require "rspec"
require "timecop"

require "pantry"

ActiveRecord::Base.establish_connection({
  adapter: "sqlite3",
  database: ":memory:"
})

# Silence warning.
ActiveRecord::Base.raise_in_transactional_callbacks = true

RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner[:active_record].strategy = :truncation
    DatabaseCleaner[:active_record].clean_with(:truncation)

    DatabaseCleaner[:redis].strategy = :truncation
    DatabaseCleaner[:redis].clean_with(:truncation)    
  end

  config.before(:each) do
    DatabaseCleaner[:active_record].start
    DatabaseCleaner[:redis].start
  end

  config.after(:each) do
    DatabaseCleaner[:active_record].clean
    DatabaseCleaner[:redis].clean
  end
end
