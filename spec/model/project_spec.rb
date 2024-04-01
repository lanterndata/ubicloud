# frozen_string_literal: true

require_relative "spec_helper"
require "octokit"

RSpec.describe Project do
  subject(:project) { described_class.new }

  describe ".has_valid_payment_method?" do
    it "sets and gets feature flags" do
      described_class.feature_flag(:dummy_flag)
      project = described_class.create_with_id(name: "dummy-name")

      expect(project.get_dummy_flag).to be_nil
      project.set_dummy_flag("new-value")
      expect(project.get_dummy_flag).to eq "new-value"
    end
  end
end
