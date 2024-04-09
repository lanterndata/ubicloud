# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "lantern" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1", provider: "gcp") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: [], provider: "gcp") }

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
    it "can not list without login" do
      visit "/lantern"

      expect(page.title).to eq("Ubicloud - Login")
    end

    it "can not create without login" do
      visit "/lantern/create"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end

  describe "authenticated" do
    before do
      Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
      login(user.email)
    end

    describe "list" do
      it "can list when there is no lantern databases" do
        visit "#{project.path}/lantern"

        expect(page.title).to eq("Ubicloud - Lantern Databases")
        expect(page).to have_content "No Lantern databases"

        click_link "New Lantern Database"
        expect(page.title).to eq("Ubicloud - Create Lantern Database")
      end

      it "can list only the lantern databases which has permissions to" do
        Prog::Lantern::LanternResourceNexus.assemble(
          project_id: project.id,
          location: "us-central1",
          name: "instance-2",
          target_vm_size: "n1-standard-2",
          target_storage_size_gib: 100,
          org_id: 0
        )

        visit "#{project.path}/lantern"

        expect(page.title).to eq("Ubicloud - Lantern Databases")
        expect(page).to have_content "instance-2"
      end
    end

    describe "create" do
      it "can create new Lantern database" do
        visit "#{project.path}/lantern/create"

        expect(page.title).to eq("Ubicloud - Create Lantern Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        choose option: "us-central1"
        choose option: "n1-standard-2"
        find_by_id("parent_id").find(:xpath, "option[1]").select_option

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content "'#{name}' will be ready in a few minutes"
        expect(LanternResource.count).to eq(1)
        expect(LanternResource.first.projects.first.id).to eq(project.id)
      end

      it "can create new Lantern database with domain" do
        visit "#{project.path}/lantern/create"

        expect(page.title).to eq("Ubicloud - Create Lantern Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        fill_in "Domain", with: "example.com"
        choose option: "us-central1"
        choose option: "n1-standard-2"
        find_by_id("parent_id").find(:xpath, "option[1]").select_option

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content "'#{name}' will be ready in a few minutes"
        expect(LanternResource.count).to eq(1)
        expect(LanternResource.first.projects.first.id).to eq(project.id)
      end

      it "can create new Lantern database from backup" do
        Prog::Lantern::LanternResourceNexus.assemble(
          project_id: project.id,
          location: "us-central1",
          name: "pg-with-permission-2",
          target_vm_size: "n1-standard-2",
          target_storage_size_gib: 100,
          lantern_version: "0.2.2",
          extras_version: "0.1.4",
          minor_version: "1"
        ).subject

        visit "#{project.path}/lantern/create"

        gcp_api = instance_double(Hosting::GcpApis)
        expect(gcp_api).to receive(:list_objects).and_return([{key: "1_backup_stop_sentinel.json", last_modified: Time.new("2024-04-07 10:10:10")}]).at_least(:once)
        expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api).at_least(:once)

        expect(page.title).to eq("Ubicloud - Create Lantern Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        choose option: "us-central1"
        choose option: "n1-standard-2"
        find_by_id("parent_id").find(:xpath, "option[2]").select_option
        find_by_id("restore_target", visible: :all).set("2024-04-08 10:10")

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content "'#{name}' will be ready in a few minutes"
        expect(LanternResource.count).to eq(2)
        expect(LanternResource.first.projects.first.id).to eq(project.id)
      end

      it "can not create Lantern database with invalid name" do
        visit "#{project.path}/lantern/create"

        expect(page.title).to eq("Ubicloud - Create Lantern Database")

        fill_in "Name", with: "invalid name"
        choose option: "us-central1"
        choose option: "n1-standard-2"
        find_by_id("parent_id").find(:xpath, "option[1]").select_option

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Lantern Database")
        expect(page).to have_content "Name must only contain"
        expect((find "input[name=name]")["value"]).to eq("invalid name")
      end

      it "can not create Lantern database with same name" do
        visit "#{project.path}/lantern/create"

        expect(page.title).to eq("Ubicloud - Create Lantern Database")

        fill_in "Name", with: pg.name
        choose option: "us-central1"
        choose option: "n1-standard-2"
        find_by_id("parent_id").find(:xpath, "option[1]").select_option

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Lantern Database")
        expect(page).to have_content "name is already taken"
      end

      it "can not create Lantern database in a project when does not have permissions" do
        project_wo_permissions
        visit "#{project_wo_permissions.path}/lantern/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end
    end
  end
end
