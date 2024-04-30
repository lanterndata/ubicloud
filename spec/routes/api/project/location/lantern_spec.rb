# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "lantern" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1", provider: "gcp") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", provider: "gcp", policy_body: []) }

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

    describe "create" do
      it "creates new lantern database" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern", {size: "n1-standard-2", name: "instance-2", org_id: 0, location: "us-central1", storage_size_gib: 100, lantern_version: "0.2.2", extras_version: "0.1.4", minor_version: "1", domain: "test.db.lantern.dev", app_env: "test", repl_password: "test-repl-pass", enable_telemetry: true, postgres_password: "test-pg-pass"}

        body = JSON.parse(last_response.body)
        expect(last_response.status).to eq(200)

        expect(body["name"]).to eq("instance-2")
        expect(body["state"]).to eq("creating")
        expect(body["instance_type"]).to eq("writer")
        expect(body["location"]).to eq("us-central1")
        expect(body["lantern_version"]).to eq("0.2.2")
        expect(body["extras_version"]).to eq("0.1.4")
        expect(body["minor_version"]).to eq("1")
        expect(body["org_id"]).to eq(0)
        expect(body["storage_size_gib"]).to eq(100)
        expect(body["domain"]).to eq("test.db.lantern.dev")
        expect(body["app_env"]).to eq("test")
        expect(body["debug"]).to be(false)
        expect(body["enable_telemetry"]).to be(true)
        expect(body["repl_user"]).to eq("repl_user")
        expect(body["repl_password"]).to eq("test-repl-pass")
        expect(body["postgres_password"]).to eq("test-pg-pass")
      end

      it "creates new lantern database with subdomain" do
        expect(Config).to receive(:lantern_top_domain).and_return("db.lantern.dev")
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern", {size: "n1-standard-2", name: "instance-2", org_id: 0, location: "us-central1", storage_size_gib: 100, lantern_version: "0.2.2", extras_version: "0.1.4", minor_version: "1", subdomain: "test", app_env: "test", repl_password: "test-repl-pass", enable_telemetry: true, postgres_password: "test-pg-pass"}

        body = JSON.parse(last_response.body)
        expect(last_response.status).to eq(200)

        expect(body["domain"]).to eq("test.db.lantern.dev")
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
        res_backups = JSON.parse(JSON.generate([{"time" => time1, "label" => "1"}, {"time" => time2, "label" => "2"}]))
        gcp_client = instance_double(Hosting::GcpApis)
        expect(gcp_client).to receive(:list_objects).and_return(backups)
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
        expect(last_response.body).to eq("Another backup is in progress please try again later")
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
  end
end
