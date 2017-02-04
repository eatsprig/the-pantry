$LOAD_PATH.unshift(File.expand_path("../lib", __FILE__))

require "pantry/version"

Gem::Specification.new do |spec|
  spec.name          = "the-pantry"
  spec.version       = Pantry::VERSION
  spec.authors       = ["sprig"]

  spec.summary       = "Before you go to the store, check the pantry!"
  spec.description   = "Simple ActiveRecord model caching using Redis."
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`
                         .split("\x0")
                         .reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "activerecord", "~> 4.2"
  spec.add_runtime_dependency "hiredis", "~> 0.6"
  spec.add_runtime_dependency "json", "~> 1.8"
  spec.add_runtime_dependency "redis", "~> 3.2"

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "database_cleaner", "~> 1.3"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec", "~> 3.3"
  spec.add_development_dependency "sqlite3", "~> 1.3"
  spec.add_development_dependency "timecop", "~> 0.7"
end
