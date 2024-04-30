# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::PageNexus do
  subject(:pn) {
    described_class.new(Strand.new).tap {
      _1.instance_variable_set(:@page, pg)
    }
  }

  let(:pg) { Page.new }

  describe "#start" do
    it "triggers page and hops" do
      expect(pg).to receive(:trigger)
      expect { pn.start }.to hop("wait")
    end
  end

  describe "#wait" do
    it "exits when resolved" do
      expect(pn).to receive(:when_resolve_set?).and_yield
      expect(pg).to receive(:resolve)
      expect { pn.wait }.to exit({"msg" => "page is resolved"})
    end

    it "naps" do
      expect { pn.wait }.to nap(30)
    end
  end

  describe "#assemble_with_logs" do
    it "does not create duplicate" do
      expect(Page).to receive(:from_tag_parts).and_return(pg)
      expect(Page).not_to receive(:create_with_id)
      described_class.assemble_with_logs("test", [], {}, "error")
    end

    it "creates a new page with logs" do
      expect(Page).to receive(:from_tag_parts).and_return(nil)
      expect(Page).to receive(:create_with_id).with(summary: "test", details: {"related_resources" => [], "logs" => {"stdout" => "test logs"}}, tag: "", severity: "error").and_return(pg)
      expect(Strand).to receive(:create)
      described_class.assemble_with_logs("test", [], {"stdout" => "test logs"}, "error")
    end
  end
end
