# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe DisplayStatusMethods do
  it "updates display_state to failed" do
    [GcpVm, LanternResource].each do |klass|
      instance = klass.new
      expect(instance).to receive(:display_state).and_return("starting")
      expect(instance).to receive(:strand).and_return(instance_double(Strand, prog: klass.name, stack: [{}])).at_least(:once)
      expect(Page).to receive(:from_tag_parts).and_return(instance_double(Page))
      expect(instance).to receive(:update).with(display_state: "failed")
      expect { instance.set_failed_on_deadline }.not_to raise_error
    end
  end
end
