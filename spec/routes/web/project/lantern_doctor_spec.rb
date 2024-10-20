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
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: [], provider: "gcp") }

  describe "authenticated" do
    before do
      Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
      login(user.email)
    end

    describe "list" do
      it "can list when there is no lantern doctor incidents" do
        visit "#{project.path}/lantern-doctor"

        expect(page.title).to eq("Ubicloud - Lantern Doctor")
        expect(page).to have_content "No Lantern Doctor incidents"
      end

      it "lists incidents" do
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
        query = LanternDoctorQuery[type: "user"]
        query.update(condition: "failed")
        LanternDoctorPage.create_incident(query, "postgres", "test", err: "test-err", output: "test-out")

        visit "#{project.path}/lantern-doctor"

        expect(page.title).to eq("Ubicloud - Lantern Doctor")
        expect(page).to have_content "Healthcheck: test system query"
      end
    end
  end
end
