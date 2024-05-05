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

    it "throws error from response if one error" do
      expect {
        described_class.check_errors(OpenStruct.new({body: JSON.dump({error: {message: "permission error", errors: []}})}))
      }.to raise_error "permission error"
    end

    it "throws error from errors if both defined" do
      expect {
        described_class.check_errors(OpenStruct.new({body: JSON.dump({error: {message: "permission error", errors: [{message: "test error"}]}})}))
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
      it "creates vm successfully with labels" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.create_vm("dummy-vm", "us-central1-a", "test", "test", "lantern", "n1-standard-1", 50, labels: {"parent" => "test"}) }.not_to raise_error
      end

      it "creates vm successfully without labels" do
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
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm/deleteAccessConfig?accessConfig=External%20NAT&networkInterface=nic0").to_return(status: 200, body: JSON.dump({"id" => "test-op"}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/operations/test-op/wait").to_return(status: 200, body: JSON.dump({"status" => "DONE"}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.delete_ephermal_ipv4("dummy-vm", "us-central1-a") }.not_to raise_error
      end
    end

    describe "#assign_static_ipv4" do
      it "gets in creating state" do
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm/addAccessConfig?networkInterface=nic0").with(body: JSON.dump({name: "External NAT", natIP: "1.1.1.1", networkTier: "PREMIUM", type: "ONE_TO_ONE_NAT"})).to_return(status: 200, body: JSON.dump({"id" => "test-op"}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/operations/test-op/wait").to_return(status: 200, body: JSON.dump({"status" => "DONE"}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect {
          api.assign_static_ipv4("dummy-vm", "1.1.1.1", "us-central1-a")
        }.not_to raise_error
      end
    end

    describe "#start_vm" do
      it "starts vm" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm/start").to_return(status: 200, body: JSON.dump({"status" => "PENDING", "id" => "test-op"}), headers: {})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/operations/test-op/wait").to_return(status: 200, body: JSON.dump({"status" => "DONE"}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.start_vm("dummy-vm", "us-central1-a") }.not_to raise_error
      end
    end

    describe "#stop_vm" do
      it "stops vm" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm/stop").to_return(status: 200, body: JSON.dump({"id" => "test-op"}), headers: {})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/operations/test-op/wait").to_return(status: 200, body: JSON.dump({"status" => "DONE"}), headers: {"Content-Type" => "application/json"})
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
          .to_return(status: 200, body: JSON.dump({"id" => "test-op"}), headers: {})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/operations/test-op/wait").to_return(status: 200, body: JSON.dump({"status" => "DONE"}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.resize_vm_disk("us-central1-a", "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/disks/test-disk", 50) }.not_to raise_error
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
        stub_request(:get, "https://storage.googleapis.com/storage/v1/b/test/o?delimiter=/&matchGlob=test").to_return(status: 200, body: JSON.dump({error: {errors: [{message: "test error"}]}}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.list_objects("test", "test") }.to raise_error "test error"
      end

      it "returns empty array" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:get, "https://storage.googleapis.com/storage/v1/b/test/o?delimiter=/&matchGlob=test").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect(api.list_objects("test", "test")).to eq([])
      end

      it "maps object names" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        t = Time.new
        stub_request(:get, "https://storage.googleapis.com/storage/v1/b/test/o?delimiter=/&matchGlob=test").to_return(status: 200, body: JSON.dump({items: [{name: "test1", updated: t}, {name: "test2", updated: t}]}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        t_str = Time.new JSON.parse(JSON.dump(t))
        expect(api.list_objects("test", "test")).to eq([{key: "test1", last_modified: t_str}, {key: "test2", last_modified: t_str}])
      end
    end

    describe "#create_service_account" do
      it "throws error from response" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://iam.googleapis.com/v1/projects/test-project/serviceAccounts").to_return(status: 200, body: JSON.dump({error: {errors: [{message: "test error"}]}}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.create_service_account("test", "test") }.to raise_error "test error"
      end

      it "creates service account" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://iam.googleapis.com/v1/projects/test-project/serviceAccounts").with(body: JSON.dump({accountId: "test", serviceAccount: {displayName: "test", description: "test"}})).to_return(status: 200, body: JSON.dump({email: "test-sa@gcp.com"}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect(api.create_service_account("test", "test")).to eq({"email" => "test-sa@gcp.com"})
      end
    end

    describe "#remove_service_account" do
      it "throws error from response" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:delete, "https://iam.googleapis.com/v1/projects/test-project/serviceAccounts/test").to_return(status: 200, body: JSON.dump({error: {errors: [{message: "test error"}]}}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.remove_service_account("test") }.to raise_error "test error"
      end

      it "removes service account" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:delete, "https://iam.googleapis.com/v1/projects/test-project/serviceAccounts/test").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect { api.remove_service_account("test") }.not_to raise_error
      end
    end

    describe "#export_service_account_key" do
      it "exports the key as b64" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://iam.googleapis.com/v1/projects/test-project/serviceAccounts/test/keys").to_return(status: 200, body: JSON.dump({privateKeyData: "test-key"}), headers: {"Content-Type" => "application/json"})
        expect(described_class).to receive(:check_errors)
        api = described_class.new
        expect(api.export_service_account_key("test")).to eq "test-key"
      end
    end

    describe "#allow_bucket_usage_by_prefix" do
      it "adds necessarry policies" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        bindings = [{role: "roles/storage.objectAdmin", members: ["serviceAccount:test-sa-old@gcp.com"]}]
        policy = {bindings: bindings, version: 1}
        bindings_new = [{role: "roles/storage.objectAdmin", members: ["serviceAccount:test-sa@gcp.com"], condition: {expression: "resource.name.startsWith(\"projects/_/buckets/test/objects/test-prefix\")", title: "Access backups for path test-prefix"}}, {role: "projects/test-project/roles/storage.objectList", members: ["serviceAccount:test-sa@gcp.com"]}]
        new_policy = {bindings: bindings + bindings_new, version: 3}
        stub_request(:get, "https://storage.googleapis.com/storage/v1/b/test/iam?optionsRequestedPolicyVersion=3").to_return(status: 200, body: JSON.dump(policy), headers: {"Content-Type" => "application/json"})
        stub_request(:put, "https://storage.googleapis.com/storage/v1/b/test/iam").with(body: JSON.dump(new_policy)).to_return(status: 200, body: "{}", headers: {"Content-Type" => "application/json"})
        expect(described_class).to receive(:check_errors).at_least(:once)
        api = described_class.new
        expect { api.allow_bucket_usage_by_prefix("test-sa@gcp.com", "test", "test-prefix") }.not_to raise_error
      end
    end

    describe "#get_json_object" do
      it "gets json from storage" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        response = {"test_key" => "test_val"}
        stub_request(:get, "https://storage.googleapis.com/storage/v1/b/test/o/test?alt=media").to_return(status: 200, body: JSON.dump(response), headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect(api.get_json_object("test", "test")).to eq(response)
      end

      it "gets invalid json from storage" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:get, "https://storage.googleapis.com/storage/v1/b/test/o/test?alt=media").to_return(status: 200, body: "test", headers: {"Content-Type" => "application/json"})
        api = described_class.new
        expect(api.get_json_object("test", "test")).to be_nil
      end
    end

    describe "#wait_for_operation" do
      it "waits for operation to be done at first attempt" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/operations/test-op/wait").to_return(status: 200, body: JSON.dump({"status" => "DONE"}), headers: {"Content-Type" => "application/json"})

        api = described_class.new
        expect { api.wait_for_operation("us-central1-a", "test-op") }.not_to raise_error
      end

      it "waits for operation until done after timeout" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/operations/test-op/wait")
          .to_raise(Excon::Error::Timeout)
          .to_return(status: 200, body: JSON.dump({"status" => "DONE"}), headers: {"Content-Type" => "application/json"})

        api = described_class.new
        expect { api.wait_for_operation("us-central1-a", "test-op") }.not_to raise_error
      end

      it "waits for operation until done" do
        stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
        stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/operations/test-op/wait")
          .to_return(status: 200, body: JSON.dump({"status" => "RUNNING"}), headers: {"Content-Type" => "application/json"})
          .to_return(status: 200, body: JSON.dump({"status" => "DONE"}), headers: {"Content-Type" => "application/json"})

        api = described_class.new
        expect { api.wait_for_operation("us-central1-a", "test-op") }.not_to raise_error
      end
    end
  end
end
