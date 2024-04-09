# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::UpdateRhizome do
  subject(:br) {
    described_class.new(Strand.new(prog: "UpdateRhizome"))
  }

  describe "#start" do
    before { br.strand.label = "start" }

    it "hops to setup" do
      expect { br.start }.to hop("setup", "UpdateRhizome")
    end
  end

  describe ".user (root)" do
    it "returns root" do
      expect(br.user).to eq("root")
    end
  end

  describe ".user (lantern)" do
    it "returns lantern" do
      st = instance_double(Strand, id: "c39ae087-6ec4-033a-d440-b7a821061caf", prog: "UpdateRhizome", stack: [{"user" => "lantern"}])
      br = described_class.new(st)
      expect(br.user).to eq("lantern")
    end
  end

  describe "#setup" do
    before { br.strand.label = "setup" }

    it "runs install rhizome" do
      expect { br.setup }.to hop("start", "InstallRhizome")
    end

    it "exits once InstallRhizome has returned" do
      br.strand.retval = {"msg" => "installed rhizome"}
      expect { br.setup }.to exit({"msg" => "rhizome updated"})
    end
  end
end
