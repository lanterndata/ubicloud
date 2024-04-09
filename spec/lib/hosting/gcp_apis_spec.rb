# frozen_string_literal: true

require "ostruct"

RSpec.describe Hosting::GcpApis do
  describe "#initialize" do
    it "fails" do
      expect(Config).to receive(:gcp_project_id).and_return(nil)
      expect {
        described_class.new
      }.to raise_error "Please set GCP_PROJECT_ID env variable"
    end

    it "fails auth" do
      expect(Config).to receive(:gcp_project_id).and_return("test-proj-id")
      expect(Google::Auth).to receive(:get_application_default).and_raise "test"
      expect {
        described_class.new
      }.to raise_error "Google Auth failed, try setting 'GOOGLE_APPLICATION_CREDENTIALS' env varialbe"
    end
  end

  describe "#check_errors" do
    it "throws error from response" do
      expect {
        described_class.check_errors(OpenStruct.new({body: JSON.dump({error: {errors: [{message: "test error"}]}})}))
      }.to raise_error "test error"
    end

    it "does not throw error" do
      expect {
        described_class.check_errors(OpenStruct.new({body: JSON.dump({error: {errors: []}})}))
      }.not_to raise_error
    end
  end

  describe "with credentials" do
    before do
      creds = instance_double(Google::Auth::GCECredentials)
      allow(creds).to receive(:apply).and_return({})
      allow(Google::Auth).to receive(:get_application_default).and_return(creds)
      allow(Config).to receive(:gcp_project_id).and_return("test-project")
    end

    describe "#create_vm" do
      it "creates vm successfully" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.create_vm("dummy-vm", "us-central1-a", "test", "test", "lantern", "n1-standard-1", 50) }.not_to raise_error
      end
    end

    describe "#get_vm" do
      it "gets vm in provisioning state" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:get, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm").to_return(status: 200, body: JSON.dump({"status" => "PROVISIONING"}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect(api.get_vm("dummy-vm", "us-central1-a")).to eq({"status" => "PROVISIONING"})
      end
    end

    describe "#create_static_ipv4" do
      it "creates static ipv4 successfully" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:get, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm").to_return(status: 200, body: JSON.dump({"status" => "RUNNING"}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/regions/us-central1/addresses").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.create_static_ipv4("dummy-vm", "us-central1") }.not_to raise_error
      end
    end

    describe "#get_static_ipv4" do
      it "gets in creating state" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:get, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm").to_return(status: 200, body: JSON.dump({"status" => "RUNNING"}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/regions/us-central1/addresses").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:get, "https://compute.googleapis.com/compute/v1/projects/test-project/regions/us-central1/addresses/dummy-vm-addr").to_return(status: 200, body: JSON.dump({status: "CREATING", address: "1.1.1.1"}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect(api.get_static_ipv4("dummy-vm", "us-central1")).to eq({"status" => "CREATING", "address" => "1.1.1.1"})
      end
    end

    describe "#delete_ephermal_ipv4" do
      it "deletes ephermal address from vm" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm/deleteAccessConfig?accessConfig=External%20NAT&networkInterface=nic0").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.delete_ephermal_ipv4("dummy-vm", "us-central1-a") }.not_to raise_error
      end
    end

    describe "#assign_static_ipv4" do
      it "gets in creating state" do
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm/addAccessConfig?networkInterface=nic0").with(body: JSON.dump({name: "External NAT", natIP: "1.1.1.1", networkTier: "PREMIUM", type: "ONE_TO_ONE_NAT"})).to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.assign_static_ipv4("dummy-vm", "1.1.1.1", "us-central1-a") }.not_to raise_error
      end
    end

    describe "#start_vm" do
      it "starts vm" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm/start").to_return(status: 200, body: "{\"status\": \"PENDING\"}", headers: {})
        api = described_class.new
        expect { api.start_vm("dummy-vm", "us-central1-a") }.not_to raise_error
      end
    end

    describe "#stop_vm" do
      it "stops vm" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm/stop").to_return(status: 200, body: "", headers: {})
        api = described_class.new
        expect { api.stop_vm("dummy-vm", "us-central1-a") }.not_to raise_error
      end
    end

    describe "#delete_vm" do
      it "deletes vm" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:delete, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm").to_return(status: 200, body: JSON.dump({"status" => "STOPPING"}), headers: {})
        api = described_class.new
        expect { api.delete_vm("dummy-vm", "us-central1-a") }.not_to raise_error
      end
    end

    describe "#release_ipv4" do
      it "deletes static ipv4 address" do
        api = described_class.new
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:delete, "https://compute.googleapis.com/compute/v1/projects/test-project/regions/us-central1/addresses/dummy-vm-addr")
        expect { api.release_ipv4("dummy-vm", "us-central1") }.not_to raise_error
      end
    end

    describe "#resize_vm_disk" do
      it "resizes vm disk" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/disks/test-disk/resize")
          .with(
            body: '{"sizeGb":"50"}'
          )
          .to_return(status: 200, body: "{}", headers: {})
        api = described_class.new
        expect { api.resize_vm_disk("https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/disks/test-disk", 50) }.not_to raise_error
      end
    end

    describe "#update_vm_type" do
      it "updates machine type" do
        stub_request(:get, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm")
          .to_return(status: 200, body: JSON.dump({machineType: "standard-2"}))
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:put, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm?mostDisruptiveAllowedAction=NONE")
          .with(
            body: "{\"machineType\":\"projects/test-project/zones/us-central1-a/machineTypes/standard-2\"}"
          )
          .to_return(status: 200, body: "{}", headers: {})
        api = described_class.new
        expect { api.update_vm_type("dummy-vm", "us-central1-a", "standard-2") }.not_to raise_error
      end
    end

    describe "#list_objects" do
      it "throws error from response" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:get, "https://storage.googleapis.com/storage/v1/b/test/o?prefix=test").to_return(status: 200, body: JSON.dump({error: {errors: [{message: "test error"}]}}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.list_objects("test", "test") }.to raise_error "test error"
      end

      it "returns empty array" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:get, "https://storage.googleapis.com/storage/v1/b/test/o?prefix=test").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect(api.list_objects("test", "test")).to eq([])
      end

      it "maps object names" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        t = Time.new
        stub_request(:get, "https://storage.googleapis.com/storage/v1/b/test/o?prefix=test").to_return(status: 200, body: JSON.dump({items: [{name: "test1", updated: t}, {name: "test2", updated: t}]}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        t_str = Time.new JSON.parse(JSON.dump(t))
        expect(api.list_objects("test", "test")).to eq([{key: "test1", last_modified: t_str}, {key: "test2", last_modified: t_str}])
      end
    end
  end
end
