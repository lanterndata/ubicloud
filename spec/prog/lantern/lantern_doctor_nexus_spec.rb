# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Lantern::LanternDoctorNexus do
  subject(:nx) { described_class.new(Strand.create(id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0", prog: "Lantern::LanternDoctorNexus", label: "start")) }

  let(:lantern_doctor) {
    instance_double(
      LanternDoctor,
      ubid: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
      id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0"
    )
  }

  before do
    allow(nx).to receive(:lantern_doctor).and_return(lantern_doctor)
  end

  describe ".assemble" do
    it "creates lantern doctor" do
      st = described_class.assemble
      doctor = LanternDoctor[st.id]
      expect(doctor).not_to be_nil
    end
  end

  describe "#start" do
    it "hops to wait resource" do
      expect(lantern_doctor).to receive(:sync_system_queries)
      expect { nx.start }.to hop("wait_resource")
    end
  end

  describe "#wait_resource" do
    it "naps if no resource yet" do
      expect(lantern_doctor).to receive(:resource).and_return(nil)
      expect { nx.wait_resource }.to nap(5)
    end

    it "naps if no resource strand yet" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, strand: nil))
      expect { nx.wait_resource }.to nap(5)
    end

    it "naps if resource is not available" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, strand: instance_double(Strand, label: "start")))
      expect { nx.wait_resource }.to nap(5)
    end

    it "hops to wait" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, strand: instance_double(Strand, label: "wait")))
      expect { nx.wait_resource }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, strand: nil))
      expect(lantern_doctor).to receive(:should_run?).and_return(false)
      expect { nx.wait }.to nap(60)
    end

    it "hops to destroy" do
      expect(lantern_doctor).to receive(:resource).and_return(nil)
      expect { nx.wait }.to hop("destroy")
    end

    it "syncs system queries" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, strand: nil))
      expect(nx).to receive(:when_sync_system_queries_set?).and_yield
      expect { nx.wait }.to hop("sync_system_queries")
    end

    it "runs queries and naps" do
      expect(lantern_doctor).to receive(:should_run?).and_return(true)
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, strand: nil))
      queries = [instance_double(LanternDoctorQuery)]
      expect(queries[0]).to receive(:run)
      expect(lantern_doctor).to receive(:queries).and_return(queries)
      expect { nx.wait }.to nap(60)
    end
  end

  describe "#before_run" do
    it "hops to destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy as strand label is not destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx).to receive(:strand).and_return(instance_double(Strand, label: "destroy"))
      expect(nx.before_run).to be_nil
    end

    it "does not hop to destroy" do
      expect(nx.before_run).to be_nil
    end
  end

  describe "#sync_system_queries" do
    it "calls sync_system_queries" do
      expect(lantern_doctor).to receive(:sync_system_queries)
      expect(nx).to receive(:decr_sync_system_queries)
      expect { nx.sync_system_queries }.to hop("wait")
    end
  end

  describe "#destroy" do
    it "exits with message" do
      expect(nx).to receive(:decr_destroy)
      page = instance_double(Page)
      query = instance_double(LanternDoctorQuery, active_pages: [page])
      expect(page).to receive(:incr_resolve)
      expect(lantern_doctor).to receive(:failed_queries).and_return([query])
      expect(lantern_doctor).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "lantern doctor is deleted"})
    end
  end
end
