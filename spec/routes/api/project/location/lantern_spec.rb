# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "lantern" do
  before do
    allow(LanternServer).to receive(:get_vm_image).and_return(Config.gcp_default_image)
  end

  let(:user) { create_account }
  let(:pg) do
    st = Prog::Lantern::LanternResourceNexus.assemble(
      project_id: project.id,
      location: "us-central1",
      name: "instance-1",
      target_vm_size: "n1-standard-2",
      target_storage_size_gib: 100,
      org_id: 0
    )
    LanternResource[st.id]
  end
  let(:pg_wo_pwermission) do
    st = Prog::Lantern::LanternResourceNexus.assemble(
      project_id: project_wo_permissions.id,
      location: "us-central1",
      name: "lantern-foo-1",
      target_vm_size: "n1-standard-2",
      target_storage_size_gib: 100,
      org_id: 0
    )

    LanternResource[st.id]
  end

  let(:project) { user.create_project_with_default_policy("project-1", provider: "gcp") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", provider: "gcp", policy_body: []) }

  describe "unauthenticated" do
    before do
      Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
    end

    it "not location list" do
      get "/api/project/#{project.ubid}/location/#{pg.location}/lantern"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not create" do
      post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/postgres_name"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not delete" do
      delete "/api/project/#{project.ubid}/location/#{pg.location}/lantern/#{pg.name}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not get" do
      get "/api/project/#{project.ubid}/location/#{pg.location}/lantern/#{pg.name}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not reset super user password" do
      post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/reset-superuser-password"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not update extension" do
      post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/update-extension"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not update image" do
      post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/update-image"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not add domain" do
      post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/add-domain"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not update rhizome" do
      post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/update-rhizome"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
      Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
    end

    describe "list" do
      it "empty" do
        get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/lantern"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"]).to eq([])
      end

      it "success single" do
        get "/api/project/#{project.ubid}/location/#{pg.location}/lantern"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(1)
      end

      it "success multiple" do
        Prog::Lantern::LanternResourceNexus.assemble(
          project_id: project.id,
          location: "us-central1",
          name: "lantern-foo-2",
          target_vm_size: "n1-standard-2",
          target_storage_size_gib: 100,
          org_id: 0
        )

        get "/api/project/#{project.ubid}/location/#{pg.location}/lantern"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(2)
      end
    end

    describe "#update-extension" do
      it "updates lantern extension" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/update-extension", {lantern_version: "0.2.4", extras_version: Config.lantern_extras_default_version}
        expect(last_response.status).to eq(200)
      end

      it "updates extras extension" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/update-extension", {extras_version: "0.2.3", lantern_version: Config.lantern_default_version}
        expect(last_response.status).to eq(200)
      end
    end

    describe "#update-image" do
      it "updates image" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/update-image", {lantern_version: "0.2.3", extras_version: "0.2.3", minor_version: "1"}
        expect(last_response.status).to eq(200)
      end
    end

    describe "get" do
      it "returns 404" do
        get "/api/project/#{project.ubid}/location/#{pg.location}/lantern/test"
        expect(last_response.status).to eq(404)
      end

      it "returns instance" do
        get "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1"
        data = JSON.parse(last_response.body)
        expect(data["name"]).to eq("instance-1")
        expect(last_response.status).to eq(200)
      end
    end

    describe "delete" do
      it "does not delete instance if has forks" do
        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        query_res = class_double(LanternResource, first: pg)
        allow(query_res).to receive(:where).and_return(query_res)
        expect(project).to receive(:lantern_resources_dataset).and_return(query_res)
        expect(pg).to receive(:forks).and_return([instance_double(LanternResource)])

        delete "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1"
        expect(last_response.status).to eq(409)
        expect(JSON.parse(last_response.body)).to eq({"error" => "Can not delete resource which has active forks"})
      end

      it "deletes instance" do
        delete "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1"
        expect(last_response.status).to eq(200)
      end
    end

    describe "start,stop,restart" do
      it "starts instance" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/start"
        expect(last_response.status).to eq(200)
      end

      it "stops instance" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/stop"
        expect(last_response.status).to eq(200)
      end

      it "restarts instance" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/restart"
        expect(last_response.status).to eq(200)
      end
    end

    describe "add-domain" do
      it "adds domain" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/add-domain", {domain: "example.com"}
        server = LanternServer.where(id: pg.representative_server.id).first
        expect(server.domain).to eq("example.com")
        expect(last_response.status).to eq(200)
      end
    end

    describe "reset-user-password" do
      it "fails validation" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/reset-user-password", {original_password: "password123!", repeat_password: "test"}
        expect(last_response.status).to eq(400)
      end

      it "resets password" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/reset-user-password", {original_password: "Password123!", repeat_password: "Password123!"}
        pg = LanternResource.first
        expect(pg.db_user_password).to eq("Password123!")
        expect(last_response.status).to eq(200)
      end
    end

    describe "update-vm" do
      it "fails validation" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/update-vm", {storage_size_gib: 10}
        expect(last_response.status).to eq(400)
      end

      it "updates storage" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/update-vm", {storage_size_gib: 200}
        server = LanternServer.where(id: pg.representative_server.id).first
        expect(server.target_storage_size_gib).to eq(200)
        expect(server.vm.storage_size_gib).to eq(200)
        expect(last_response.status).to eq(200)
      end

      it "updates vm size" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/update-vm", {size: "n1-standard-4"}
        server = LanternServer.where(id: pg.representative_server.id).first
        expect(server.target_vm_size).to eq("n1-standard-4")
        expect(last_response.status).to eq(200)
      end
    end

    describe "backups" do
      it "maps and prettifies backup keys correctly" do
        time1 = Time.now - 20 * 60
        time2 = Time.now - 10 * 60
        ubid = LanternServer.where(id: pg.representative_server.id).first.timeline.ubid
        backups = [{last_modified: time1, key: "#{ubid}/basebackups_005/1_backup_stop_sentinel.json"}, {last_modified: time2, key: "#{ubid}/basebackups_005/2_backup_stop_sentinel.json"}]
        res_backups = JSON.parse(JSON.generate([{"time" => time1, "label" => "1", "compressed_size" => 10, "uncompressed_size" => 20}, {"time" => time2, "label" => "2", "compressed_size" => 10, "uncompressed_size" => 20}]))
        gcp_client = instance_double(Hosting::GcpApis)
        expect(gcp_client).to receive(:list_objects).and_return(backups)
        expect(gcp_client).to receive(:get_json_object).and_return({"CompressedSize" => 10, "UncompressedSize" => 20}).at_least(:once)
        allow(Hosting::GcpApis).to receive(:new).and_return(gcp_client)

        get "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/backups"
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to eq(res_backups)
      end
    end

    describe "push-backup" do
      it "creates new backup" do
        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        query_res = class_double(LanternResource, first: pg)
        allow(query_res).to receive(:where).and_return(query_res)
        expect(project).to receive(:lantern_resources_dataset).and_return(query_res)
        expect(pg.timeline).to receive(:take_manual_backup)

        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/push-backup"
        expect(last_response.status).to eq(200)
      end

      it "fails to create new backup" do
        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        query_res = class_double(LanternResource, first: pg)
        allow(query_res).to receive(:where).and_return(query_res)
        expect(project).to receive(:lantern_resources_dataset).and_return(query_res)
        expect(pg.timeline).to receive(:take_manual_backup).and_raise "Another backup is in progress please try again later"

        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/push-backup"
        expect(last_response.status).to eq(409)
        expect(JSON.parse(last_response.body)).to eq({"error" => "Another backup is in progress please try again later"})
      end

      it "fails to create new backup with unknown" do
        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        query_res = class_double(LanternResource, first: pg)
        allow(query_res).to receive(:where).and_return(query_res)
        expect(project).to receive(:lantern_resources_dataset).and_return(query_res)
        expect(pg.timeline).to receive(:take_manual_backup).and_raise "Unknown error"

        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/push-backup"
        expect(last_response.status).to eq(400)
      end
    end

    describe "dissociate-forks" do
      it "dissociate-forkses" do
        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        query_res = class_double(LanternResource, first: pg)
        allow(query_res).to receive(:where).and_return(query_res)
        expect(project).to receive(:lantern_resources_dataset).and_return(query_res)
        expect(pg).to receive(:dissociate_forks)
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/instance-1/dissociate-forks"
        expect(last_response.status).to eq(200)
      end
    end
  end
end
