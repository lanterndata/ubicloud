# frozen_string_literal: true

require_relative "../spec_helper"

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

  let(:project) { user.create_project_with_default_policy("project-1", provider: "gcp") }

  describe "unauthenticated" do
    it "not list" do
      get "/api/project/#{project.ubid}/lantern"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
      Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
    end

    it "success all servers" do
      Prog::Lantern::LanternResourceNexus.assemble(
        project_id: project.id,
        location: "us-central1",
        name: "lantern-foo-1",
        target_vm_size: "n1-standard-2",
        target_storage_size_gib: 100
      )

      Prog::Lantern::LanternResourceNexus.assemble(
        project_id: project.id,
        location: "us-central1",
        name: "lantern-foo-2",
        target_vm_size: "n1-standard-2",
        target_storage_size_gib: 100
      )

      get "/api/project/#{project.ubid}/lantern"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end

    describe "create" do
      it "creates new lantern database" do
        post "/api/project/#{project.ubid}/lantern", {size: "n1-standard-2", name: "instance-2", label: "test-label", org_id: 0, location: "us-central1", storage_size_gib: 100, lantern_version: "0.2.2", extras_version: "0.1.4", minor_version: "1", domain: "test.db.lantern.dev", app_env: "test", repl_password: "test-repl-pass", enable_telemetry: true, postgres_password: "test-pg-pass"}

        body = JSON.parse(last_response.body)
        expect(last_response.status).to eq(200)

        serv = LanternResource[name: "instance-2"].representative_server
        expect(body["name"]).to eq("instance-2")
        expect(body["label"]).to eq("test-label")
        expect(body["state"]).to eq("creating")
        expect(body["instance_type"]).to eq("writer")
        expect(body["location"]).to eq("us-central1")
        expect(body["lantern_version"]).to eq("0.2.2")
        expect(body["extras_version"]).to eq("0.1.4")
        expect(body["minor_version"]).to eq("1")
        expect(body["org_id"]).to eq(0)
        expect(body["storage_size_gib"]).to eq(100)
        expect(serv.strand.stack.first["domain"]).to eq("test.db.lantern.dev")
        expect(body["app_env"]).to eq("test")
        expect(body["debug"]).to be(false)
        expect(body["enable_telemetry"]).to be(true)
        expect(body["repl_user"]).to eq("repl_user")
        expect(body["repl_password"]).to eq("test-repl-pass")
        expect(body["postgres_password"]).to eq("test-pg-pass")
      end

      it "creates new lantern database from backup" do
        expect(LanternResource).to receive(:[]).and_call_original.twice
        expect(LanternResource).to receive(:[]).with(pg.id).and_return(pg)
        expect(LanternResource).to receive(:[]).and_call_original.at_least(:once)
        expect(pg.timeline).to receive(:refresh_earliest_backup_completion_time).at_least(:once)
        expect(pg.timeline).to receive(:earliest_restore_time).and_return(Time.new - 1000000).at_least(:once)
        expect(pg.timeline).to receive(:latest_restore_time).and_return(Time.new).at_least(:once)
        post "/api/project/#{project.ubid}/lantern", {size: "n1-standard-2", name: "instance-from-backup", org_id: 0, location: "us-central1", domain: "test.db.lantern.dev", parent_id: pg.id}

        body = JSON.parse(last_response.body)

        expect(last_response.status).to eq(200)

        serv = LanternResource[name: "instance-from-backup"].representative_server
        expect(body["name"]).to eq("instance-from-backup")
        expect(body["state"]).to eq("creating")
        expect(body["instance_type"]).to eq("writer")
        expect(body["location"]).to eq("us-central1")
        expect(body["lantern_version"]).to eq(pg.representative_server.lantern_version)
        expect(body["extras_version"]).to eq(pg.representative_server.extras_version)
        expect(body["minor_version"]).to eq(pg.representative_server.minor_version)
        expect(body["org_id"]).to eq(0)
        expect(body["storage_size_gib"]).to eq(pg.representative_server.target_storage_size_gib)
        expect(serv.strand.stack.first["domain"]).to eq("test.db.lantern.dev")
        expect(body["app_env"]).to eq("test")
        expect(body["debug"]).to be(false)
        expect(body["enable_telemetry"]).to be(true)
        expect(body["repl_user"]).to eq("repl_user")
        expect(body["repl_password"]).to eq(pg.repl_password)
        expect(body["postgres_password"]).to eq(pg.superuser_password)
      end

      it "creates new lantern database from backup with wrong restore time" do
        post "/api/project/#{project.ubid}/lantern", {size: "n1-standard-2", name: "instance-from-backup", org_id: 0, location: "us-central1", domain: "test.db.lantern.dev", parent_id: pg.id, restore_target: "Test"}

        expect(last_response.status).to eq(400)
      end

      it "creates new lantern database from backup with restore time" do
        expect(LanternResource).to receive(:[]).and_call_original.twice
        expect(LanternResource).to receive(:[]).with(pg.id).and_return(pg)
        expect(LanternResource).to receive(:[]).and_call_original.at_least(:once)
        expect(pg.timeline).to receive(:refresh_earliest_backup_completion_time).at_least(:once)
        expect(pg.timeline).to receive(:earliest_restore_time).and_return(Time.new - 1000000).at_least(:once)
        expect(pg.timeline).to receive(:latest_restore_time).and_return(Time.new).at_least(:once)
        post "/api/project/#{project.ubid}/lantern", {size: "n1-standard-2", name: "instance-from-backup", org_id: 0, location: "us-central1", parent_id: pg.id, restore_target: Time.now - 1000}

        body = JSON.parse(last_response.body)

        expect(last_response.status).to eq(200)

        expect(body["name"]).to eq("instance-from-backup")
        expect(body["state"]).to eq("creating")
        expect(body["instance_type"]).to eq("writer")
        expect(body["location"]).to eq("us-central1")
        expect(body["lantern_version"]).to eq(pg.representative_server.lantern_version)
        expect(body["extras_version"]).to eq(pg.representative_server.extras_version)
        expect(body["minor_version"]).to eq(pg.representative_server.minor_version)
        expect(body["org_id"]).to eq(0)
        expect(body["storage_size_gib"]).to eq(pg.representative_server.target_storage_size_gib)
        expect(body["app_env"]).to eq("test")
        expect(body["debug"]).to be(false)
        expect(body["enable_telemetry"]).to be(true)
        expect(body["repl_user"]).to eq("repl_user")
        expect(body["repl_password"]).to eq(pg.repl_password)
        expect(body["postgres_password"]).to eq(pg.superuser_password)
      end

      it "creates new lantern database with subdomain" do
        expect(Config).to receive(:lantern_top_domain).and_return("db.lantern.dev")
        post "/api/project/#{project.ubid}/lantern", {size: "n1-standard-2", name: "instance-2", org_id: 0, location: "us-central1", storage_size_gib: 100, lantern_version: "0.2.2", extras_version: "0.1.4", minor_version: "1", subdomain: "test", app_env: "test", repl_password: "test-repl-pass", enable_telemetry: true, postgres_password: "test-pg-pass"}

        JSON.parse(last_response.body)
        expect(last_response.status).to eq(200)

        serv = LanternResource[name: "instance-2"].representative_server
        expect(serv.strand.stack.first["domain"]).to eq("test.db.lantern.dev")
      end
    end
  end
end
