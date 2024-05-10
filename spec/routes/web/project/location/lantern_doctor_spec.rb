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

  describe "authenticated" do
    before do
      login(user.email)
      Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
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
        doctor_page = LanternDoctorPage.create_incident(first_query, "postgres", err: "test-err", output: "test-out")
        expect(doctor_page.status).to eq("new")

        visit "/project/#{project.ubid}/lantern-doctor"
        expect(page.title).to eq("Ubicloud - Lantern Doctor")
        click_button "Trigger"
        expect(page.status_code).to eq(200)
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
        doctor_page = LanternDoctorPage.create_incident(first_query, "postgres", err: "test-err", output: "test-out")
        expect(doctor_page.status).to eq("new")

        visit "/project/#{project.ubid}/lantern-doctor"
        expect(page.title).to eq("Ubicloud - Lantern Doctor")
        click_button "Ack"
        expect(page.status_code).to eq(200)
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
        doctor_page = LanternDoctorPage.create_incident(first_query, "postgres", err: "test-err", output: "test-out")
        expect(doctor_page.status).to eq("new")

        visit "/project/#{project.ubid}/lantern-doctor"
        expect(page.title).to eq("Ubicloud - Lantern Doctor")
        click_button "Resolve"
        expect(page.status_code).to eq(200)
      end

      it "returns 404" do
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
        doctor_page = LanternDoctorPage.create_incident(first_query, "postgres", err: "test-err", output: "test-out")
        expect(doctor_page.status).to eq("new")

        visit "/project/#{project.ubid}/lantern-doctor"
        expect(page.title).to eq("Ubicloud - Lantern Doctor")
        expect(LanternDoctorPage).to receive(:[]).with(doctor_page.id).and_return(nil)
        click_button "Resolve"
        expect(page.status_code).to eq(404)
      end
    end
  end
end
