# frozen_string_literal: true

if (suite = ENV.delete("COVERAGE"))
  require "simplecov"

  SimpleCov.start do
    enable_coverage :branch
    minimum_coverage line: 100, branch: 100
    minimum_coverage_by_file line: 100, branch: 100

    command_name "#{suite}#{ENV["TEST_ENV_NUMBER"]}"

    # rhizome (dataplane) and controlplane should have separate coverage reports.
    # They will have different coverage suites in future.
    if !ENV.has_key?("E2E_TEST")
      add_filter "/rhizome"
    end

    # No need to check coverage for them
    add_filter "/misc"
    add_filter "/migrate/"
    add_filter "/spec/"
    add_filter "/db.rb"
    add_filter "/model.rb"
    add_filter "/loader.rb"
    add_filter "/.env.rb"
    add_filter "/demo/migrate_existing_db.rb"

    add_group("Missing") { |src| src.covered_percent < 100 }
    add_group("Covered") { |src| src.covered_percent == 100 }

    track_files "**/*.rb"
  end
end
