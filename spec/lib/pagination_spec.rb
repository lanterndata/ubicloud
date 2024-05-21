# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Pagination do
  before do
    api = instance_double(Hosting::GcpApis)
    allow(Hosting::GcpApis).to receive(:new).and_return(api)
    allow(api).to receive_messages(create_service_account: {"email" => "test-sa"}, export_service_account_key: "test-key")
    allow(api).to receive(:allow_bucket_usage_by_prefix)
    allow(api).to receive(:allow_access_to_big_query_table)
    allow(LanternServer).to receive(:get_vm_image).and_return(Config.gcp_default_image)
  end

  let(:project) { Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) } }

  let!(:first_server) do
    Prog::Lantern::LanternResourceNexus.assemble(location: "us-central1", target_vm_size: "n1-standard-2", target_storage_size_gib: 50, name: "test", project_id: project.id).subject
  end

  let!(:second_server) do
    Prog::Lantern::LanternResourceNexus.assemble(location: "us-central1", target_vm_size: "n1-standard-2", target_storage_size_gib: 50, name: "test2", project_id: project.id).subject
  end

  describe "#validate_paginated_result" do
    describe "success" do
      it "order column" do
        result = project.lantern_resources_dataset.paginated_result(order_column: "name")
        expect(result[:records][0].ubid).to eq(first_server.ubid)
        expect(result[:records][1].ubid).to eq(second_server.ubid)
      end

      it "page size 1" do
        result = project.lantern_resources_dataset.paginated_result(page_size: 1)
        expect(result[:records].length).to eq(1)
        expect(result[:count]).to eq(2)
      end

      it "page size 2" do
        result = project.lantern_resources_dataset.paginated_result(page_size: 2)
        expect(result[:records].length).to eq(2)
        expect(result[:count]).to eq(2)
      end

      it "next cursor" do
        result = project.lantern_resources_dataset.paginated_result(page_size: 1, order_column: "name")
        expect(result[:next_cursor]).to eq(second_server.ubid)
      end

      it "negative page size" do
        result = project.lantern_resources_dataset.paginated_result(page_size: -1)
        expect(result[:records].length).to eq(1)
      end

      it "big page size" do
        101.times do |index|
          Prog::Lantern::LanternResourceNexus.assemble(location: "us-central1", target_vm_size: "n1-standard-2", target_storage_size_gib: 50, name: "additional-lantern-#{index}", project_id: project.id).subject
        end

        result = project.lantern_resources_dataset.paginated_result(page_size: 1000)
        expect(result[:records].length).to eq(100)
      end

      it "non numeric page size" do
        result = project.lantern_resources_dataset.paginated_result(page_size: "foo")
        expect(result[:records].length).to eq(1)
      end

      it "cursor" do
        result = project.lantern_resources_dataset.paginated_result(cursor: second_server.ubid)
        expect(result[:records][0].ubid).to eq(second_server.ubid)
      end
    end

    describe "unsuccesful" do
      it "invalid cursor" do
        expect { project.lantern_resources_dataset.paginated_result(cursor: "invalidubid") }.to raise_error(Validation::ValidationFailed)
      end

      it "invalid order column" do
        expect { project.lantern_resources_dataset.paginated_result(order_column: "non-existing-column") }.to raise_error(Validation::ValidationFailed)
      end
    end
  end
end
