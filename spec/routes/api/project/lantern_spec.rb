# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "lantern" do
  let(:user) { create_account }

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
      lantern_project = Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
    end

    it "success all servers" do
      Prog::Lantern::LanternServerNexus.assemble(
        project_id: project.id,
        location: "us-central1",
        name: "lantern-foo-1",
        target_vm_size: "standard-2",
        storage_size_gib: 100
      )

      Prog::Lantern::LanternServerNexus.assemble(
        project_id: project.id,
        location: "us-central1",
        name: "lantern-foo-2",
        target_vm_size: "standard-2",
        storage_size_gib: 100
      )

      get "/api/project/#{project.ubid}/lantern"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end
  end

end
