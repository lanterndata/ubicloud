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
  let(:pg_wo_permission) do
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
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: [], provider: "gcp") }

  describe "authenticated" do
    before do
      Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
      login(user.email)
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

    describe "reset-user-password" do
      it "can update user password" do
        visit "#{project.path}#{pg.path}"
        expect(page).to have_content "Reset user password"

        fill_in "New password", with: "DummyPassword123"
        fill_in "New password (repeat)", with: "DummyPassword123"
        click_button "Reset"

        expect(page.status_code).to eq(200)
      end

      it "does not show reset user password for reader" do
        pg.representative_server.update(timeline_access: "fetch")

        visit "#{project.path}#{pg.path}"
        expect(page).to have_no_content "Reset user password"
        expect(page.status_code).to eq(200)
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

    describe "update-extension" do
      it "can update lantern extension" do
        visit "#{project.path}#{pg.path}"
        fill_in "lantern_version", with: "0.2.1"
        click_button "Update Extensions"
        pg = LanternResource.first
        expect(pg.representative_server.lantern_version).to eq("0.2.1")
        expect(page.status_code).to eq(200)
      end

      it "can update lantern_extras extension" do
        visit "#{project.path}#{pg.path}"
        fill_in "extras_version", with: "0.1.1"
        click_button "Update Extensions"
        pg = LanternResource.first
        expect(pg.representative_server.extras_version).to eq("0.1.1")
        expect(page.status_code).to eq(200)
      end

      it "can update both extension" do
        visit "#{project.path}#{pg.path}"
        fill_in "lantern_version", with: "0.2.0"
        fill_in "extras_version", with: "0.1.0"
        click_button "Update Extensions"
        pg = LanternResource.first
        expect(pg.representative_server.lantern_version).to eq("0.2.0")
        expect(pg.representative_server.extras_version).to eq("0.1.0")
        expect(page.status_code).to eq(200)
      end
    end

    describe "update-image" do
      it "can update image" do
        visit "#{project.path}#{pg.path}"
        fill_in "img_lantern_version", with: "0.2.0"
        fill_in "img_extras_version", with: "0.1.0"
        fill_in "img_minor_version", with: "2"
        click_button "Update Image"
        pg = LanternResource.first
        expect(pg.representative_server.lantern_version).to eq("0.2.0")
        expect(pg.representative_server.extras_version).to eq("0.1.0")
        expect(pg.representative_server.minor_version).to eq("2")
        expect(page.status_code).to eq(200)
      end
    end

    describe "add-domain" do
      it "can add domain" do
        visit "#{project.path}#{pg.path}"
        fill_in "domain", with: "example.com"
        click_button "Add domain"
        pg = LanternResource.first
        expect(pg.representative_server.domain).to eq("example.com")
      end
    end

    describe "update-vm" do
      it "fails validation" do
        visit "#{project.path}#{pg.path}"
        fill_in "storage_size_gib", with: "1"
        click_button "Update VM"
        expect(page).to have_content "storage_size_gib can not be smaller than "
        expect(page.status_code).to eq(200)
      end

      it "updates validation" do
        visit "#{project.path}#{pg.path}"
        fill_in "storage_size_gib", with: "200"
        click_button "Update VM"
        expect(page.status_code).to eq(200)
      end

      it "updates vm size" do
        visit "#{project.path}#{pg.path}"
        select "n1-standard-4", from: "size"
        click_button "Update VM"
        expect(page.status_code).to eq(200)
      end
    end

    describe "add-replica" do
      it "can add a replica server" do
        visit "#{project.path}#{pg.path}"
        fill_in "replica_lantern_version", with: "0.2.0"
        fill_in "replica_extras_version", with: "0.1.0"
        fill_in "replica_minor_version", with: "2"
        select "n1-standard-2", from: "replica_vm_size"
        click_button "Add Replica"
        expect(page).to have_content "A new replica server is being added"
        expect(page.status_code).to eq(200)
      end
    end

    describe "promote-replica" do
      it "can promote replica server" do
        query_res = class_double(LanternResource, first: pg)
        allow(query_res).to receive(:where).and_return(query_res)
        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        allow(project).to receive(:lantern_resources_dataset).and_return(query_res)
        replica = instance_double(LanternServer, primary?: false, display_state: "running", id: "pg2", ubid: "pg2", instance_type: "reader", lantern_version: "0.3.0", extras_version: "0.2.5", minor_version: "1", target_vm_size: "n1-standard-2", target_storage_size_gib: 50, connection_string: "pg://")
        allow(pg).to receive(:servers).and_return([*pg.servers, replica])
        expect(replica).to receive(:incr_take_over)

        visit "#{project.path}#{pg.path}"
        click_button "Promote"
        expect(page.status_code).to eq(200)
      end
    end

    describe "delete-replica" do
      it "can delete a replica server" do
        query_res = class_double(LanternResource, first: pg)
        allow(query_res).to receive(:where).and_return(query_res)
        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        allow(project).to receive(:lantern_resources_dataset).and_return(query_res)
        replica = instance_double(LanternServer, primary?: false, display_state: "running", id: "pg2", ubid: "pg2", instance_type: "reader", lantern_version: "0.3.0", extras_version: "0.2.5", minor_version: "1", target_vm_size: "n1-standard-2", target_storage_size_gib: 50, connection_string: "pg://")
        allow(pg).to receive(:servers).and_return([*pg.servers, replica])
        expect(replica).to receive(:incr_destroy)

        visit "#{project.path}#{pg.path}"
        btn = find "#postgres-delete-replica-pg2 .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
        expect(page.body).to eq({message: "Deleting replica"}.to_json)
        expect(page.status_code).to eq(200)
      end

      it "cannot delete primary server" do
        query_res = class_double(LanternResource, first: pg)
        allow(query_res).to receive(:where).and_return(query_res)
        expect(Project).to receive(:from_ubid).and_return(project).at_least(:once)
        allow(project).to receive(:lantern_resources_dataset).and_return(query_res)
        serv = instance_double(LanternServer, display_state: "running", id: "pg2", ubid: "pg2", instance_type: "writer", lantern_version: "0.3.0", extras_version: "0.2.5", minor_version: "1", target_vm_size: "n1-standard-2", target_storage_size_gib: 50, connection_string: "pg://")
        expect(serv).to receive(:primary?).and_return(false, false, true)
        allow(pg).to receive(:servers).and_return([*pg.servers, serv])

        visit "#{project.path}#{pg.path}"
        btn = find "#postgres-delete-replica-pg2 .delete-btn"
        page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}
        expect(JSON.parse(page.body)["message"]).to eq("Cannot delete primary server")
        expect(page.status_code).to eq(200)
      end
    end
  end
end
