# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "lantern" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1", provider: "gcp") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: [], provider: "gcp") }

  let(:pg) do
    Prog::Lantern::LanternServerNexus.assemble(
      project_id: project.id,
      location: "us-central1",
      name: "pg-with-permission",
      target_vm_size: "standard-2",
      storage_size_gib: 100
    ).subject
  end

  let(:pg_wo_permission) do
    Prog::Lantern::LanternServerNexus.assemble(
      project_id: project_wo_permissions.id,
      location: "us-central1",
      name: "pg-without-permission",
      target_vm_size: "standard-2",
      storage_size_gib: 100
    ).subject
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
      lantern_project = Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
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
        pg
        pg_wo_permission
        visit "#{project.path}/lantern"

        expect(page.title).to eq("Ubicloud - Lantern Databases")
        expect(page).to have_content pg.name
        expect(page).to have_no_content pg_wo_permission.name
      end
    end

    describe "create" do
      it "can create new Lantern database" do
        visit "#{project.path}/lantern/create"

        expect(page.title).to eq("Ubicloud - Create Lantern Database")
        name = "new-pg-db"
        fill_in "Name", with: name
        choose option: "us-central1"
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - #{name}")
        expect(page).to have_content "'#{name}' will be ready in a few minutes"
        expect(LanternServer.count).to eq(1)
        expect(LanternServer.first.projects.first.id).to eq(project.id)
      end

      it "can not create Lantern database with invalid name" do
        visit "#{project.path}/lantern/create"

        expect(page.title).to eq("Ubicloud - Create Lantern Database")

        fill_in "Name", with: "invalid name"
        choose option: "us-central1"
        choose option: "standard-2"

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
        choose option: "standard-2"

        click_button "Create"

        expect(page.title).to eq("Ubicloud - Create Lantern Database")
        expect(page).to have_content "name is already taken"
      end

      it "can not create PostgreSQL database in a project when does not have permissions" do
        project_wo_permissions
        visit "#{project_wo_permissions.path}/lantern/create"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      describe "show" do
        it "can show Lantern database details" do
          pg
          visit "#{project.path}/lantern"

          expect(page.title).to eq("Ubicloud - Lantern Databases")
          expect(page).to have_content pg.name

          click_link "Show", href: "#{project.path}#{pg.path}"

          expect(page.title).to eq("Ubicloud - #{pg.name}")
          expect(page).to have_content pg.name
        end

        it "raises forbidden when does not have permissions" do
          visit "#{project_wo_permissions.path}#{pg_wo_permission.path}"

          expect(page.title).to eq("Ubicloud - Forbidden")
          expect(page.status_code).to eq(403)
          expect(page).to have_content "Forbidden"
        end

        it "raises not found when Lantern database not exists" do
          visit "#{project.path}/location/us-central1/lantern/08s56d4kaj94xsmrnf5v5m3mav"

          expect(page.title).to eq("Ubicloud - Resource not found")
          expect(page.status_code).to eq(404)
          expect(page).to have_content "Resource not found"
        end
      end

      describe "delete" do
        it "can delete Lantern database" do
          visit "#{project.path}#{pg.path}"

          # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
          # UI tests run without a JavaScript enginer.
          btn = find "#postgres-delete-#{pg.ubid} .delete-btn"
          page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

          expect(page.body).to eq({message: "Deleting #{pg.name}"}.to_json)
          expect(SemSnap.new(pg.id).set?("destroy")).to be true
        end

        it "can not delete Lantern database when does not have permissions" do
          # Give permission to view, so we can see the detail page
          project_wo_permissions.access_policies.first.update(body: {
            acls: [
              {subjects: user.hyper_tag_name, actions: ["Postgres:view"], objects: project_wo_permissions.hyper_tag_name}
            ]
          })

          visit "#{project_wo_permissions.path}#{pg_wo_permission.path}"

          expect { find ".delete-btn" }.to raise_error Capybara::ElementNotFound
        end
      end
    end
  end
end
