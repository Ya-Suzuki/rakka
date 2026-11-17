# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rakka"
  spec.version = "0.1.0"
  spec.authors = ["Ya-Suzuki"]
  spec.email = ["32971744+Ya-Suzuki@users.noreply.github.com"]

  spec.summary = "Ractor-based Actor Event Sourcing for Ruby"
  spec.description = "A Ruby library for building event-sourced applications using Ractor for true parallelism. Inspired by Akka."
  spec.homepage = "https://github.com/Ya-Suzuki/rakka"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.files = Dir.chdir(__dir__) do
    Dir["{lib}/**/*", "LICENSE", "README.md"]
  end

  spec.require_paths = ["lib"]

  # Optional dependencies
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "pg", "~> 1.5"
end
