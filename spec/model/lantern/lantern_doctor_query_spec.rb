# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe LanternDoctorQuery do
  subject(:lantern_doctor_query) {
    described_class.new do |r|
      r.sql = "SELECT 1"
      r.name = "test"
      r.db_name = "postgres"
      r.severity = "error"
      r.schedule = "*/1 * * * *"
      r.id = "6181ddb3-0002-8ad0-9aeb-084832c9273b"
      r.response_type = "bool"
      r.server_type = "primary"
    end
  }

  let(:parent) {
    instance_double(
      described_class,
      sql: "SELECT 2",
      name: "test-parent",
      db_name: "*",
      severity: "critical",
      schedule: "*/2 * * * *"
    )
  }

  describe "#parent_properties" do
    it "returns parent sql if parent_id is defined else self sql" do
      expect(lantern_doctor_query).to receive(:parent).and_return(nil)
      expect(lantern_doctor_query.sql).to be("SELECT 1")

      expect(lantern_doctor_query).to receive(:parent).and_return(parent)
      expect(lantern_doctor_query.sql).to be("SELECT 2")
    end

    it "returns parent name if parent_id is defined else self name" do
      expect(lantern_doctor_query).to receive(:parent).and_return(nil)
      expect(lantern_doctor_query.name).to be("test")

      expect(lantern_doctor_query).to receive(:parent).and_return(parent)
      expect(lantern_doctor_query.name).to be("test-parent")
    end

    it "returns parent db_name if parent_id is defined else self db_name" do
      expect(lantern_doctor_query).to receive(:parent).and_return(nil)
      expect(lantern_doctor_query.db_name).to be("postgres")

      expect(lantern_doctor_query).to receive(:parent).and_return(parent)
      expect(lantern_doctor_query.db_name).to be("*")
    end

    it "returns parent severity if parent_id is defined else self severity" do
      expect(lantern_doctor_query).to receive(:parent).and_return(nil)
      expect(lantern_doctor_query.severity).to be("error")

      expect(lantern_doctor_query).to receive(:parent).and_return(parent)
      expect(lantern_doctor_query.severity).to be("critical")
    end

    it "returns parent schedule if parent_id is defined else self schedule" do
      expect(lantern_doctor_query).to receive(:parent).and_return(nil)
      expect(lantern_doctor_query.schedule).to be("*/1 * * * *")

      expect(lantern_doctor_query).to receive(:parent).and_return(parent)
      expect(lantern_doctor_query.schedule).to be("*/2 * * * *")
    end

    it "returns parent fn_label if parent_id is defined else self fn_label" do
      expect(lantern_doctor_query).to receive(:parent).and_return(nil)
      expect(lantern_doctor_query.fn_label).to be_nil

      expect(lantern_doctor_query).to receive(:parent).and_return(parent)
      expect(parent).to receive(:fn_label).and_return("test")
      expect(lantern_doctor_query.fn_label).to be("test")
    end

    it "returns parent response_type if parent_id is defined else self response_type" do
      expect(lantern_doctor_query).to receive(:parent).and_return(nil)
      expect(lantern_doctor_query.response_type).to eq("bool")

      expect(lantern_doctor_query).to receive(:parent).and_return(parent)
      expect(parent).to receive(:response_type).and_return("rows")
      expect(lantern_doctor_query.response_type).to be("rows")
    end

    it "returns parent server_type if parent_id is defined else self server_type" do
      expect(lantern_doctor_query).to receive(:parent).and_return(nil)
      expect(lantern_doctor_query.server_type).to eq("primary")

      expect(lantern_doctor_query).to receive(:parent).and_return(parent)
      expect(parent).to receive(:server_type).and_return("standby")
      expect(lantern_doctor_query.server_type).to be("standby")
    end

    it "returns task_name" do
      expect(lantern_doctor_query.task_name).to eq("healthcheck_#{lantern_doctor_query.ubid}")
    end
  end

  describe "#servers" do
    it "returns primary servers based on server_type" do
      serv1 = instance_double(LanternServer)
      serv2 = instance_double(LanternServer)
      allow(serv1).to receive_messages(primary?: true, standby?: false)
      allow(serv2).to receive_messages(primary?: false, standby?: true)

      resource = instance_double(LanternResource, servers: [serv1, serv2])
      doctor = instance_double(LanternDoctor, resource: resource)
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor)
      expect(lantern_doctor_query.servers).to eq([serv1])
    end

    it "returns standby servers based on server_type" do
      serv1 = instance_double(LanternServer)
      serv2 = instance_double(LanternServer)
      allow(serv1).to receive_messages(primary?: true, standby?: false)
      allow(serv2).to receive_messages(primary?: false, standby?: true)

      resource = instance_double(LanternResource, servers: [serv1, serv2])
      doctor = instance_double(LanternDoctor, resource: resource)
      allow(lantern_doctor_query).to receive(:server_type).and_return("standby")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor)
      expect(lantern_doctor_query.servers).to eq([serv2])
    end

    it "returns all servers based on server_type" do
      serv1 = instance_double(LanternServer)
      serv2 = instance_double(LanternServer)
      allow(serv1).to receive_messages(primary?: true, standby?: false)
      allow(serv2).to receive_messages(primary?: false, standby?: true)

      resource = instance_double(LanternResource, servers: [serv1, serv2])
      doctor = instance_double(LanternDoctor, resource: resource)
      allow(lantern_doctor_query).to receive(:server_type).and_return("*")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor)
      expect(lantern_doctor_query.servers).to eq([serv1, serv2])
    end
  end

  describe "#should_run?" do
    it "return false if not yet time for run" do
      min = Time.new.min
      modified_min = (min == 59) ? 0 : min + 1

      expect(lantern_doctor_query).to receive(:last_checked).and_return(Time.new)
      expect(lantern_doctor_query).to receive(:schedule).and_return("#{modified_min} * * * *").at_least(:once)
      expect(lantern_doctor_query.should_run?).to be(false)
    end

    it "return false if in progress" do
      serv = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      resource = instance_double(LanternResource, representative_server: serv)
      doctor = instance_double(LanternDoctor, resource: resource)
      expect(serv.vm.sshable).to receive(:cmd).and_return("InProgress")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor)
      expect(lantern_doctor_query.should_run?).to be(false)
    end

    it "return true if it is the same time for run" do
      serv = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      resource = instance_double(LanternResource, representative_server: serv)
      doctor = instance_double(LanternDoctor, resource: resource)
      expect(serv.vm.sshable).to receive(:cmd).and_return("NotStarted")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor)
      ts = Time.new
      min = ts.min
      expect(Time).to receive(:new).and_return(ts).at_least(:once)
      expect(lantern_doctor_query).to receive(:last_checked).and_return(nil)
      expect(lantern_doctor_query).to receive(:schedule).and_return("#{min} * * * *").at_least(:once)
      expect(lantern_doctor_query.should_run?).to be(true)
    end

    it "return true if the running time was passed but didn't run yet" do
      serv = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      resource = instance_double(LanternResource, representative_server: serv)
      doctor = instance_double(LanternDoctor, resource: resource)
      expect(serv.vm.sshable).to receive(:cmd).and_return("NotStarted")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor)
      min = Time.new.min
      modified_min = (min == 0) ? 59 : min - 1

      expect(lantern_doctor_query).to receive(:last_checked).and_return(Time.new - 60 * 5).at_least(:once)
      expect(lantern_doctor_query).to receive(:schedule).and_return("#{modified_min} * * * *").at_least(:once)
      expect(lantern_doctor_query.should_run?).to be(true)
    end
  end

  describe "#is_system?" do
    it "returns false if no parent" do
      expect(lantern_doctor_query).to receive(:parent).and_return(nil)
      expect(lantern_doctor_query.is_system?).to be(false)
    end

    it "returns true if has parent" do
      expect(lantern_doctor_query).to receive(:parent).and_return(parent)
      expect(lantern_doctor_query.is_system?).to be(true)
    end
  end

  describe "#user" do
    it "returns postgres if system query" do
      expect(lantern_doctor_query).to receive(:is_system?).and_return(true)
      expect(lantern_doctor_query.user).to be("postgres")
    end

    it "returns db user if not system query" do
      expect(lantern_doctor_query).to receive(:is_system?).and_return(false)
      expect(lantern_doctor_query).to receive(:doctor).and_return(instance_double(LanternDoctor, resource: instance_double(LanternResource, db_user: "test")))
      expect(lantern_doctor_query.user).to be("test")
    end
  end

  describe "#page" do
    it "lists active pages" do
      serv = instance_double(LanternServer, ubid: "test-ubid")
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b", label: "test-label")
      doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")
      query = described_class.create_with_id(type: "user")
      expect(query).to receive(:doctor).and_return(doctor).at_least(:once)
      p1 = LanternDoctorPage.create_incident(query, "pg1", "test", err: "", output: "")
      p2 = LanternDoctorPage.create_incident(query, "pg2", "test", err: "", output: "")
      p3 = LanternDoctorPage.create_incident(query, "pg3", "test", err: "", output: "")
      LanternDoctorPage.create_incident(query, "pg4", "test", err: "", output: "")

      p1.trigger
      p2.resolve
      p3.ack

      pages = query.active_pages
      expect(pages.size).to be(2)
      expect(pages[0].id).to eq(p1.id)
    end

    it "lists new and active pages" do
      serv = instance_double(LanternServer, ubid: "test-ubid")
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b", label: "test-label")
      doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")
      query = described_class.create_with_id(type: "user")
      expect(query).to receive(:doctor).and_return(doctor).at_least(:once)
      p1 = LanternDoctorPage.create_incident(query, "pg1", "test", err: "", output: "")
      p2 = LanternDoctorPage.create_incident(query, "pg2", "test", err: "", output: "")
      p3 = LanternDoctorPage.create_incident(query, "pg3", "test", err: "", output: "")
      LanternDoctorPage.create_incident(query, "pg4", "test", err: "", output: "")

      p1.trigger
      p2.resolve
      p3.ack

      pages = query.new_and_active_pages
      expect(pages.size).to be(3)
    end
  end

  describe "#update_page_status" do
    it "creates incident" do
      query_res = class_double(LanternDoctorPage)
      expect(query_res).to receive(:where).and_return(class_double(LanternDoctorPage, first: nil))
      expect(LanternDoctorPage).to receive(:where).and_return(query_res)
      expect(LanternDoctorPage).to receive(:create_incident)
      expect { lantern_doctor_query.update_page_status("postgres", "test", false, "", "test") }.not_to raise_error
    end

    it "resolves" do
      p1 = instance_double(LanternDoctorPage)
      expect(p1).to receive(:resolve)
      query_res = class_double(LanternDoctorPage)
      expect(query_res).to receive(:where).and_return(class_double(LanternDoctorPage, first: p1))
      expect(LanternDoctorPage).to receive(:where).and_return(query_res)
      expect { lantern_doctor_query.update_page_status("postgres", "test", true, "", "test") }.not_to raise_error
    end

    it "do nothing" do
      p1 = instance_double(LanternDoctorPage)
      expect(p1).not_to receive(:resolve)
      query_res = class_double(LanternDoctorPage)
      expect(query_res).to receive(:where).and_return(class_double(LanternDoctorPage, first: p1))
      expect(LanternDoctorPage).to receive(:where).and_return(query_res)
      expect { lantern_doctor_query.update_page_status("postgres", "test", false, "", "test") }.not_to raise_error
    end
  end
end
