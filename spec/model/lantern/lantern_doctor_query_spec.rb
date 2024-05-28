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
  end

  describe "#should_run?" do
    it "return false if not yet time for run" do
      min = Time.new.min
      modified_min = (min == 59) ? 0 : min + 1

      expect(lantern_doctor_query).to receive(:last_checked).and_return(Time.new)
      expect(lantern_doctor_query).to receive(:schedule).and_return("#{modified_min} * * * *").at_least(:once)
      expect(lantern_doctor_query.should_run?).to be(false)
    end

    it "return true if it is the same time for run" do
      ts = Time.new
      min = ts.min
      expect(Time).to receive(:new).and_return(ts).at_least(:once)
      expect(lantern_doctor_query).to receive(:last_checked).and_return(nil)
      expect(lantern_doctor_query).to receive(:schedule).and_return("#{min} * * * *").at_least(:once)
      expect(lantern_doctor_query.should_run?).to be(true)
    end

    it "return true if the running time was passed but didn't run yet" do
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

  describe "#run" do
    it "returns if should not run yet" do
      expect(lantern_doctor_query).to receive(:should_run?).and_return(false)
      expect(lantern_doctor_query.run).to be_nil
    end

    it "runs query on specified database" do
      serv = instance_double(LanternServer)
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test")
      doctor = instance_double(LanternDoctor, resource: resource)
      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: lantern_doctor_query.db_name, user: resource.db_user).and_return("f")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query).to receive(:should_run?).and_return(true)
      expect(lantern_doctor_query).to receive(:update).with(hash_including(condition: "healthy"))
      expect { lantern_doctor_query.run }.not_to raise_error
    end

    it "throws error if no sql defined" do
      serv = instance_double(LanternServer, ubid: "test-ubid")
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b", label: "test-label")
      doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")

      expect(lantern_doctor_query).to receive(:sql).and_return(nil).at_least(:once)
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query).to receive(:should_run?).and_return(true)
      expect(lantern_doctor_query).to receive(:update).with(hash_including(condition: "failed"))
      expect(LanternDoctorPage).to receive(:create_incident).with(lantern_doctor_query, "postgres", err: "BUG: non-system query without sql", output: "")

      expect { lantern_doctor_query.run }.not_to raise_error
    end

    it "throws error if wrong response_type" do
      serv = instance_double(LanternServer, ubid: "test-ubid")
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b", label: "test-label")
      doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")

      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "postgres", user: resource.db_user).and_return("f")
      expect(lantern_doctor_query).to receive(:response_type).and_return("test").at_least(:once)
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query).to receive(:should_run?).and_return(true)
      expect(lantern_doctor_query).to receive(:update).with(hash_including(condition: "failed"))
      expect(LanternDoctorPage).to receive(:create_incident).with(lantern_doctor_query, "postgres", err: "BUG: invalid response type (test) on query test", output: "")

      expect { lantern_doctor_query.run }.not_to raise_error
    end

    it "runs function for specified database" do
      serv = instance_double(LanternServer)
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test")
      doctor = instance_double(LanternDoctor, resource: resource)

      expect(parent).to receive(:db_name).and_return("postgres")
      expect(lantern_doctor_query).to receive(:fn_label).and_return("check_daemon_embedding_jobs").at_least(:once)
      expect(lantern_doctor_query).to receive(:parent).and_return(parent).at_least(:once)

      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query).to receive(:is_system?).and_return(true).at_least(:once)
      expect(lantern_doctor_query).to receive(:should_run?).and_return(true).at_least(:once)
      expect(lantern_doctor_query).to receive(:check_daemon_embedding_jobs).and_return("f")
      expect(lantern_doctor_query).to receive(:response_type).and_return("bool").at_least(:once)
      expect(lantern_doctor_query).to receive(:update).with(hash_including(condition: "healthy"))

      expect { lantern_doctor_query.run }.not_to raise_error
    end

    it "runs query on all databases" do
      serv = instance_double(LanternServer)
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test")
      doctor = instance_double(LanternDoctor, resource: resource)
      dbs = ["db1", "db2"]

      expect(serv).to receive(:list_all_databases).and_return(dbs)

      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "db1", user: resource.db_user).and_return("f")
      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "db2", user: resource.db_user).and_return("f")

      expect(lantern_doctor_query).to receive(:db_name).and_return("*")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query).to receive(:should_run?).and_return(true)
      expect(lantern_doctor_query).to receive(:update).with(hash_including(condition: "healthy"))

      expect { lantern_doctor_query.run }.not_to raise_error
    end

    it "runs query on all databases and errors" do
      serv = instance_double(LanternServer, ubid: "test-ubid")
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b", label: "test-label")
      doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")
      dbs = ["db1", "db2"]

      expect(serv).to receive(:list_all_databases).and_return(dbs)

      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "db1", user: resource.db_user).and_raise("test-err")
      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "db2", user: resource.db_user).and_return("f")

      expect(lantern_doctor_query).to receive(:db_name).and_return("*")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query).to receive(:should_run?).and_return(true)
      expect(lantern_doctor_query).to receive(:update).with(hash_including(condition: "failed"))
      expect(LanternDoctorPage).to receive(:create_incident).with(lantern_doctor_query, "db1", err: "test-err", output: "")

      expect { lantern_doctor_query.run }.not_to raise_error
    end

    it "runs query on all databases and fails" do
      serv = instance_double(LanternServer, ubid: "test-ubid")
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b", label: "test-label")
      doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")
      dbs = ["db1", "db2"]

      expect(serv).to receive(:list_all_databases).and_return(dbs)

      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "db1", user: resource.db_user).and_return("t")
      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "db2", user: resource.db_user).and_return("f")

      expect(lantern_doctor_query).to receive(:db_name).and_return("*")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query).to receive(:should_run?).and_return(true)
      expect(lantern_doctor_query).to receive(:update).with(hash_including(condition: "failed"))
      expect(LanternDoctorPage).to receive(:create_incident).with(lantern_doctor_query, "db1", err: "", output: "")

      expect { lantern_doctor_query.run }.not_to raise_error
    end

    it "runs query on all databases and fails with rows" do
      serv = instance_double(LanternServer, ubid: "test-ubid")
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b", label: "test-label")
      doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")
      dbs = ["db1", "db2"]

      expect(serv).to receive(:list_all_databases).and_return(dbs)

      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "db1", user: resource.db_user).and_return("r1\nr2")
      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "db2", user: resource.db_user).and_return("")

      expect(lantern_doctor_query).to receive(:response_type).and_return("rows").at_least(:once)
      expect(lantern_doctor_query).to receive(:db_name).and_return("*")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query).to receive(:should_run?).and_return(true)
      expect(lantern_doctor_query).to receive(:update).with(hash_including(condition: "failed"))
      expect(LanternDoctorPage).to receive(:create_incident).with(lantern_doctor_query, "db1", err: "", output: "r1\nr2")

      expect { lantern_doctor_query.run }.not_to raise_error
    end

    it "does not create duplicate page" do
      serv = instance_double(LanternServer, ubid: "test-ubid")
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b")
      doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")
      dbs = ["db1", "db2"]

      expect(serv).to receive(:list_all_databases).and_return(dbs)

      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "db1", user: resource.db_user).and_return("t")
      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "db2", user: resource.db_user).and_return("f")

      expect(lantern_doctor_query).to receive(:db_name).and_return("*")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query).to receive(:should_run?).and_return(true)
      expect(lantern_doctor_query).to receive(:update).with(hash_including(condition: "failed"))
      first_dataset = instance_double(Sequel::Dataset, first: instance_double(LanternDoctorPage))
      second_dataset = instance_double(Sequel::Dataset, first: nil)
      expect(first_dataset).to receive(:where).with(Sequel.lit("status != 'resolved' ")).and_return(first_dataset)
      expect(second_dataset).to receive(:where).with(Sequel.lit("status != 'resolved' ")).and_return(second_dataset)
      expect(LanternDoctorPage).to receive(:where).with(query_id: lantern_doctor_query.id, db: "db1").and_return(first_dataset)
      expect(LanternDoctorPage).to receive(:where).with(query_id: lantern_doctor_query.id, db: "db2").and_return(second_dataset)

      expect { lantern_doctor_query.run }.not_to raise_error
    end

    it "runs query on all databases and resolves previous error" do
      serv = instance_double(LanternServer, ubid: "test-ubid")
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b")
      doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")
      dbs = ["db1", "db2"]

      expect(serv).to receive(:list_all_databases).and_return(dbs)

      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "db1", user: resource.db_user).and_return("f")
      expect(serv).to receive(:run_query).with(lantern_doctor_query.sql, db: "db2", user: resource.db_user).and_return("f")

      expect(lantern_doctor_query).to receive(:db_name).and_return("*")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query).to receive(:should_run?).and_return(true)
      expect(lantern_doctor_query).to receive(:update).with(hash_including(condition: "healthy"))
      page1 = instance_double(LanternDoctorPage)
      page2 = instance_double(LanternDoctorPage)

      first_dataset = instance_double(Sequel::Dataset, first: page1)
      second_dataset = instance_double(Sequel::Dataset, first: page2)
      expect(first_dataset).to receive(:where).with(Sequel.lit("status != 'resolved' ")).and_return(first_dataset)
      expect(second_dataset).to receive(:where).with(Sequel.lit("status != 'resolved' ")).and_return(second_dataset)
      expect(LanternDoctorPage).to receive(:where).with(query_id: lantern_doctor_query.id, db: "db1").and_return(first_dataset)
      expect(LanternDoctorPage).to receive(:where).with(query_id: lantern_doctor_query.id, db: "db2").and_return(second_dataset)
      expect(page1).to receive(:resolve)
      expect(page2).to receive(:resolve)

      expect { lantern_doctor_query.run }.not_to raise_error
    end
  end

  describe "#check_disk_space_usage" do
    it "fails if primary disk server usage is above 90%" do
      serv1 = instance_double(LanternServer, primary?: true, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      serv2 = instance_double(LanternServer, primary?: false, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(serv1.vm.sshable).to receive(:cmd).and_return("91")
      expect(serv2.vm.sshable).to receive(:cmd).and_return("80")
      doctor = instance_double(LanternDoctor, resource: instance_double(LanternResource, servers: [serv1, serv2]), ubid: "test-ubid")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query.check_disk_space_usage("postgres", "postgres")).to eq("primary server - usage 91%")
    end

    it "fails if standby disk usage is above 90%" do
      serv1 = instance_double(LanternServer, primary?: true, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      serv2 = instance_double(LanternServer, primary?: false, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(serv1.vm.sshable).to receive(:cmd).and_return("11")
      expect(serv2.vm.sshable).to receive(:cmd).and_return("92")
      doctor = instance_double(LanternDoctor, resource: instance_double(LanternResource, servers: [serv1, serv2]), ubid: "test-ubid")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query.check_disk_space_usage("postgres", "postgres")).to eq("standby server - usage 92%")
    end

    it "succceds if all servers disk usage is under 90%" do
      serv1 = instance_double(LanternServer, primary?: true, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      serv2 = instance_double(LanternServer, primary?: false, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(serv1.vm.sshable).to receive(:cmd).and_return("11")
      expect(serv2.vm.sshable).to receive(:cmd).and_return("22")
      doctor = instance_double(LanternDoctor, resource: instance_double(LanternResource, servers: [serv1, serv2]), ubid: "test-ubid")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(lantern_doctor_query.check_disk_space_usage("postgres", "postgres")).to eq("")
    end
  end

  describe "#check_daemon_embedding_jobs" do
    it "fails if not backend db connection" do
      expect(LanternBackend).to receive(:db).and_return(nil)
      expect { lantern_doctor_query.check_daemon_embedding_jobs "postgres", "postgres" }.to raise_error "No connection to lantern backend database specified"
    end

    it "get jobs and fails" do
      serv = instance_double(LanternServer, ubid: "test-ubid")
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b")
      doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(LanternBackend).to receive(:db).and_return(DB).at_least(:once)
      expect(LanternBackend.db).to receive(:select)
        .and_return(instance_double(Sequel::Dataset,
          from: instance_double(Sequel::Dataset,
            where: instance_double(Sequel::Dataset,
              where: instance_double(Sequel::Dataset,
                where: instance_double(Sequel::Dataset,
                  all: [{schema: "public", table: "test", src_column: "test-src", dst_column: "test-dst"}]))))))
      expect(serv).to receive(:run_query).with("SELECT (SELECT COUNT(*) FROM \"public\".\"test\" WHERE \"test-src\" IS NOT NULL AND \"test-src\" != '' AND \"test-src\" != 'Error: Summary failed (llm)' AND \"test-dst\" IS NULL) > 1000", db: "postgres", user: "postgres").and_return("t")
      expect(lantern_doctor_query.check_daemon_embedding_jobs("postgres", "postgres")).to eq("t")
    end

    it "get jobs as empty" do
      serv = instance_double(LanternServer, ubid: "test-ubid")
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b")
      doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")
      expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
      expect(LanternBackend).to receive(:db).and_return(DB).at_least(:once)
      expect(LanternBackend.db).to receive(:select)
        .and_return(instance_double(Sequel::Dataset,
          from: instance_double(Sequel::Dataset,
            where: instance_double(Sequel::Dataset,
              where: instance_double(Sequel::Dataset,
                where: instance_double(Sequel::Dataset,
                  all: []))))))
      expect(lantern_doctor_query.check_daemon_embedding_jobs("postgres", "postgres")).to eq("f")
    end
  end

  it "get jobs and succceds" do
    serv = instance_double(LanternServer, ubid: "test-ubid")
    resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b")
    doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")
    expect(lantern_doctor_query).to receive(:doctor).and_return(doctor).at_least(:once)
    expect(LanternBackend).to receive(:db).and_return(DB).at_least(:once)
    expect(LanternBackend.db).to receive(:select)
      .and_return(instance_double(Sequel::Dataset,
        from: instance_double(Sequel::Dataset,
          where: instance_double(Sequel::Dataset,
            where: instance_double(Sequel::Dataset,
              where: instance_double(Sequel::Dataset,
                all: [{schema: "public", table: "test", src_column: "test-src", dst_column: "test-dst"}]))))))
    expect(serv).to receive(:run_query).with("SELECT (SELECT COUNT(*) FROM \"public\".\"test\" WHERE \"test-src\" IS NOT NULL AND \"test-src\" != '' AND \"test-src\" != 'Error: Summary failed (llm)' AND \"test-dst\" IS NULL) > 1000", db: "postgres", user: "postgres").and_return("f")
    expect(lantern_doctor_query.check_daemon_embedding_jobs("postgres", "postgres")).to eq("f")
  end

  describe "#page" do
    it "lists active pages" do
      serv = instance_double(LanternServer, ubid: "test-ubid")
      resource = instance_double(LanternResource, representative_server: serv, db_user: "test", name: "test-res", id: "6181ddb3-0002-8ad0-9aeb-084832c9273b", label: "test-label")
      doctor = instance_double(LanternDoctor, resource: resource, ubid: "test-ubid")
      query = described_class.create_with_id(type: "user")
      expect(query).to receive(:doctor).and_return(doctor).at_least(:once)
      p1 = LanternDoctorPage.create_incident(query, "pg1", err: "", output: "")
      p2 = LanternDoctorPage.create_incident(query, "pg2", err: "", output: "")
      p3 = LanternDoctorPage.create_incident(query, "pg3", err: "", output: "")
      LanternDoctorPage.create_incident(query, "pg4", err: "", output: "")

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
      p1 = LanternDoctorPage.create_incident(query, "pg1", err: "", output: "")
      p2 = LanternDoctorPage.create_incident(query, "pg2", err: "", output: "")
      p3 = LanternDoctorPage.create_incident(query, "pg3", err: "", output: "")
      LanternDoctorPage.create_incident(query, "pg4", err: "", output: "")

      p1.trigger
      p2.resolve
      p3.ack

      pages = query.new_and_active_pages
      expect(pages.size).to be(3)
    end
  end
end
