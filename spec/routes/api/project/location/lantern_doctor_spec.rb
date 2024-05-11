# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "lantern-doctor" do
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

  before do
    allow(LanternServer).to receive(:get_vm_image).and_return(Config.gcp_default_image)
  end

  describe "authenticated" do
    before do
      login_api(user.email)
      Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
    end

    describe "list" do
      it "lists empty" do
        get "/api/project/#{project.ubid}/location/#{pg.location}/lantern/#{pg.name}/doctor"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"]).to eq([])
      end

      it "lists queries" do
        system_query = LanternDoctorQuery.create_with_id(
          name: "test system query",
          db_name: "postgres",
          schedule: "*/30 * * * *",
          condition: "unknown",
          sql: "SELECT 1<2",
          type: "system",
          severity: "error"
        )
        pg.doctor.sync_system_queries

        get "/api/project/#{project.ubid}/location/#{pg.location}/lantern/#{pg.name}/doctor"
        expect(last_response.status).to eq(200)
        items = JSON.parse(last_response.body)["items"]
        expect(items.size).to eq(1)
        first_item = items[0]
        expect(first_item["id"]).not_to be_nil
        expect(first_item["name"]).to eq(system_query.name)
        expect(first_item["db_name"]).to eq(system_query.db_name)
        expect(first_item["schedule"]).to eq(system_query.schedule)
        expect(first_item["type"]).to eq("user")
        expect(first_item["severity"]).to eq(system_query.severity)
      end
    end

    describe "incidents" do
      it "trigger incident for user" do
        LanternDoctorQuery.create_with_id(
          name: "test system query",
          db_name: "postgres",
          schedule: "*/30 * * * *",
          condition: "unknown",
          sql: "SELECT 1<2",
          type: "system",
          severity: "error"
        )
        pg.doctor.sync_system_queries
        pg.doctor.queries
        first_query = LanternDoctorQuery[doctor_id: pg.doctor.id]
        first_query.update(condition: "failed")
        page = LanternDoctorPage.create_incident(first_query, "postgres", err: "test-err", output: "test-out")
        expect(page.status).to eq("new")

        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/#{pg.name}/doctor/incidents/#{page.id}/trigger"
        expect(last_response.status).to eq(204)
        page = LanternDoctorPage[page.id]
        expect(page.status).to eq("triggered")
      end

      it "trigger incident (not found)" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/#{pg.name}/doctor/incidents/#{pg.id}/trigger"
        expect(last_response.status).to eq(404)
      end

      it "ack incident for user" do
        LanternDoctorQuery.create_with_id(
          name: "test system query",
          db_name: "postgres",
          schedule: "*/30 * * * *",
          condition: "unknown",
          sql: "SELECT 1<2",
          type: "system",
          severity: "error"
        )
        pg.doctor.sync_system_queries
        pg.doctor.queries
        first_query = LanternDoctorQuery[doctor_id: pg.doctor.id]
        first_query.update(condition: "failed")
        page = LanternDoctorPage.create_incident(first_query, "postgres", err: "test-err", output: "test-out")
        expect(page.status).to eq("new")

        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/#{pg.name}/doctor/incidents/#{page.id}/ack"
        expect(last_response.status).to eq(204)
        page = LanternDoctorPage[page.id]
        expect(page.status).to eq("acknowledged")
      end

      it "resolve incident for user" do
        LanternDoctorQuery.create_with_id(
          name: "test system query",
          db_name: "postgres",
          schedule: "*/30 * * * *",
          condition: "unknown",
          sql: "SELECT 1<2",
          type: "system",
          severity: "error"
        )
        pg.doctor.sync_system_queries
        pg.doctor.queries
        first_query = LanternDoctorQuery[doctor_id: pg.doctor.id]
        first_query.update(condition: "failed")
        page = LanternDoctorPage.create_incident(first_query, "postgres", err: "test-err", output: "test-out")
        expect(page.status).to eq("new")

        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/#{pg.name}/doctor/incidents/#{page.id}/resolve"
        expect(last_response.status).to eq(204)
        page = LanternDoctorPage[page.id]
        expect(page.status).to eq("resolved")
      end

      it "lists active incidents" do
        LanternDoctorQuery.create_with_id(
          name: "test system query",
          db_name: "postgres",
          schedule: "*/30 * * * *",
          condition: "unknown",
          sql: "SELECT 1<2",
          type: "system",
          severity: "error"
        )
        pg.doctor.sync_system_queries
        pg.doctor.queries
        first_query = LanternDoctorQuery[doctor_id: pg.doctor.id]
        first_query.update(condition: "failed")
        page = LanternDoctorPage.create_incident(first_query, "postgres", err: "test-err", output: "test-out")
        page.trigger

        get "/api/project/#{project.ubid}/location/#{pg.location}/lantern/#{pg.name}/doctor/incidents"
        expect(last_response.status).to eq(200)
        items = JSON.parse(last_response.body)["items"]
        expect(items.size).to eq(1)
        first_item = items[0]
        expect(first_item["condition"]).to eq("failed")
        incidents = first_item["incidents"]
        expect(incidents.size).to eq(1)

        expect(incidents[0]["summary"]).to eq("Healthcheck: test system query failed on instance-1 - no-label (postgres)")
        expect(incidents[0]["error"]).to eq("test-err")
        expect(incidents[0]["output"]).to eq("test-out")
      end

      it "changes check time of query to run on next loop" do
        LanternDoctorQuery.create_with_id(
          name: "test system query",
          db_name: "postgres",
          schedule: "*/30 * * * *",
          condition: "unknown",
          sql: "SELECT 1<2",
          type: "system",
          severity: "error"
        )
        pg.doctor.sync_system_queries
        pg.doctor.queries
        first_query = LanternDoctorQuery[doctor_id: pg.doctor.id]
        t = Time.new
        first_query.update(last_checked: t)

        post "/api/project/#{project.ubid}/location/#{pg.location}/lantern/#{pg.name}/doctor/#{first_query.id}/run"
        expect(last_response.status).to eq(204)
        get "/api/project/#{project.ubid}/location/#{pg.location}/lantern/#{pg.name}/doctor"
        expect(last_response.status).to eq(200)
        items = JSON.parse(last_response.body)["items"]
        expect(items.size).to eq(1)
        first_item = items[0]
        expect(first_item["last_checked"]).to be_nil
      end

      it "returns 404" do
        get "/api/project/#{project.ubid}/location/#{pg.location}/lantern/#{pg.name}/doctor/fbdad2ba-b61e-89b7-b7e5-d3414b94c541/run"
        expect(last_response.status).to eq(404)
      end
    end
  end
end
