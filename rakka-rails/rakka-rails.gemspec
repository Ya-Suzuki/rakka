# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rakka-rails"
  spec.version = "0.1.0"
  spec.authors = ["Your Name"]
  spec.email = ["your@email.com"]

  spec.summary = "Rails integration for Rakka"
  spec.description = "Rails integration for Rakka - Ractor-based Actor Event Sourcing. Provides generators, Railtie, and ActiveRecord configuration bridging."
  spec.homepage = "https://github.com/yourusername/rakka"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.files = Dir.chdir(__dir__) do
    Dir["{lib}/**/*", "LICENSE", "README.md"]
  end

  spec.require_paths = ["lib"]

  spec.add_dependency "rakka", "~> 0.1"
  spec.add_dependency "rails", ">= 7.0"
  spec.add_dependency "pg", "~> 1.5"
end
