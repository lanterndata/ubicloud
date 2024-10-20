# frozen_string_literal: true

RSpec.describe BillingRate do
  it "each rate has a unique ID" do
    expect(described_class.rates.map { _1["id"] }.size).to eq(described_class.rates.map { _1["id"] }.uniq.size)
  end

  describe ".line_item_description" do
    it "returns for VmCores" do
      expect(described_class.line_item_description("VmCores", "n1-standard", 4)).to eq("n1-standard-8 Virtual Machine")
    end

    it "raises exception for unknown type" do
      expect { described_class.line_item_description("NewType", "NewFamily", 1) }.to raise_error("BUG: Unknown resource type for line item description")
    end

    it "each resource type has a description" do
      described_class.rates.each do |rate|
        expect(described_class.line_item_description(rate["resource_type"], rate["resource_family"], 1)).not_to be_nil
      end
    end
  end
end
