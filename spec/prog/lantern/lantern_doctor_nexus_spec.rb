# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Lantern::LanternDoctorNexus do
  subject(:nx) { described_class.new(Strand.create(id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0", prog: "Lantern::LanternDoctorNexus", label: "start")) }

  let(:sshable) { instance_double(Sshable) }
  let(:vm) { instance_double(GcpVm, sshable: sshable, name: "test-vm") }
  let(:server) { instance_double(LanternServer, vm: vm, primary?: true) }

  let(:lantern_doctor) {
    instance_double(
      LanternDoctor,
      ubid: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
      id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0"
    )
  }

  before do
    allow(nx).to receive(:lantern_doctor).and_return(lantern_doctor)
  end

  describe ".assemble" do
    it "creates lantern doctor" do
      st = described_class.assemble
      doctor = LanternDoctor[st.id]
      expect(doctor).not_to be_nil
    end
  end

  describe "#start" do
    it "hops to wait resource" do
      expect(lantern_doctor).to receive(:sync_system_queries)
      expect { nx.start }.to hop("wait_resource")
    end
  end

  describe "#wait_resource" do
    it "naps if no resource yet" do
      expect(lantern_doctor).to receive(:resource).and_return(nil)
      expect { nx.wait_resource }.to nap(5)
    end

    it "naps if no resource strand yet" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, strand: nil))
      expect { nx.wait_resource }.to nap(5)
    end

    it "naps if resource is not available" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, strand: instance_double(Strand, label: "start")))
      expect { nx.wait_resource }.to nap(5)
    end

    it "hops to wait" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, strand: instance_double(Strand, label: "wait")))
      expect { nx.wait_resource }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, strand: nil))
      expect(lantern_doctor).to receive(:should_run?).and_return(false)
      expect { nx.wait }.to nap(60)
    end

    it "hops to destroy" do
      expect(lantern_doctor).to receive(:resource).and_return(nil)
      expect { nx.wait }.to hop("destroy")
    end

    it "syncs system queries" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, strand: nil))
      expect(nx).to receive(:when_sync_system_queries_set?).and_yield
      expect { nx.wait }.to hop("sync_system_queries")
    end

    it "hops to run_queries" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, strand: nil))
      expect(lantern_doctor).to receive(:should_run?).and_return(true)
      expect { nx.wait }.to hop("run_queries")
    end
  end

  describe "#before_run" do
    it "hops to destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy as strand label is not destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx).to receive(:strand).and_return(instance_double(Strand, label: "destroy"))
      expect(nx.before_run).to be_nil
    end

    it "does not hop to destroy" do
      expect(nx.before_run).to be_nil
    end
  end

  describe "#sync_system_queries" do
    it "calls sync_system_queries" do
      expect(lantern_doctor).to receive(:sync_system_queries)
      expect(nx).to receive(:decr_sync_system_queries)
      expect { nx.sync_system_queries }.to hop("wait")
    end
  end

  describe "#destroy" do
    it "exits with message" do
      expect(nx).to receive(:decr_destroy)
      page = instance_double(Page)
      query = instance_double(LanternDoctorQuery, new_and_active_pages: [page])
      expect(page).to receive(:resolve)
      expect(lantern_doctor).to receive(:failed_queries).and_return([query])
      expect(lantern_doctor).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "lantern doctor is deleted"})
    end
  end

  describe "#run_queries" do
    before do
      allow(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, representative_server: server))
      allow(server).to receive(:list_all_databases).and_return(["test_db"])
      allow(sshable).to receive(:cmd).and_return("command executed")
    end

    describe "#run_queries" do
      it "runs queries on the specified servers" do
        query1 = instance_double(LanternDoctorQuery, servers: [server], db_name: "*")
        query2 = instance_double(LanternDoctorQuery, servers: [server])
        expect(query1).to receive(:should_run?).and_return(true)
        expect(query1).to receive(:is_system?).and_return(true)
        expect(query1).to receive(:response_type).and_return("bool")
        expect(query1).to receive(:name).and_return("test_query")
        expect(query1).to receive(:sql).and_return("SELECT 1")
        expect(query1).to receive(:user).and_return("postgres")
        expect(query1).to receive(:fn_label).and_return(nil)
        expect(query1).to receive(:task_name).and_return("healthcheck_test_query")
        expect(query2).to receive(:should_run?).and_return(false)
        expect(lantern_doctor).to receive(:queries).and_return([query1, query2])
        expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'lantern/bin/doctor/run_query' healthcheck_test_query", stdin: JSON.generate({query: {is_system: true, response_type: "bool", name: "test_query", sql: "SELECT 1", fn_label: nil, query_user: "postgres"}, server_type: "primary", dbs: ["test_db"]}))

        expect { nx.run_queries }.to hop("wait_queries")
      end

      it "runs queries on the specified database" do
        query1 = instance_double(LanternDoctorQuery, servers: [server], db_name: "postgres")
        query2 = instance_double(LanternDoctorQuery, servers: [server])
        expect(server).to receive(:primary?).and_return(false)
        expect(query1).to receive(:should_run?).and_return(true)
        expect(query1).to receive(:is_system?).and_return(true)
        expect(query1).to receive(:response_type).and_return("bool")
        expect(query1).to receive(:name).and_return("test_query")
        expect(query1).to receive(:sql).and_return(nil)
        expect(query1).to receive(:fn_label).and_return("check_daemon_embedding_jobs")
        expect(query1).to receive(:user).and_return("postgres")
        expect(query1).to receive(:task_name).and_return("healthcheck_test_query")
        expect(query2).to receive(:should_run?).and_return(false)
        expect(lantern_doctor).to receive(:queries).and_return([query1, query2])
        expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'lantern/bin/doctor/run_query' healthcheck_test_query", stdin: JSON.generate({query: {is_system: true, response_type: "bool", name: "test_query", sql: nil, fn_label: "check_daemon_embedding_jobs", query_user: "postgres"}, server_type: "standby", dbs: ["postgres"]}))

        expect { nx.run_queries }.to hop("wait_queries")
      end

      it "skips" do
        query1 = instance_double(LanternDoctorQuery, servers: [server], db_name: "postgres")
        expect(query1).to receive(:servers).and_return([])
        expect(query1).to receive(:should_run?).and_return(true)
        expect(lantern_doctor).to receive(:queries).and_return([query1])
        expect { nx.run_queries }.to hop("wait_queries")
      end
    end

    describe "#wait_queries" do
      before do
        allow(sshable).to receive(:cmd).with("common/bin/daemonizer --check test_query").and_return("Succeeded")
        allow(sshable).to receive(:cmd).with("common/bin/daemonizer --logs test_query").and_return(JSON.generate({"stdout" => '[{"db": "test_db", "result": "success"}]', "stderr" => ""}))
        allow(sshable).to receive(:cmd).with("common/bin/daemonizer --clean test_query").and_return("cleaned")
      end

      it "checks the status of queries and updates accordingly" do
        query = instance_double(LanternDoctorQuery, servers: [server], db_name: "postgres", task_name: "test_query")
        expect(lantern_doctor).to receive(:queries).and_return([query])
        expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check test_query")
        expect(sshable).to receive(:cmd).with("common/bin/daemonizer --logs test_query")
        expect(sshable).to receive(:cmd).with("common/bin/daemonizer --clean test_query")
        expect(query).to receive(:update_page_status).with("*", vm.name, true, nil, nil)
        expect(query).to receive(:update_page_status).with("test_db", vm.name, true, "success", nil)
        expect(query).to receive(:update).with(condition: "healthy", last_checked: instance_of(Time))

        expect { nx.wait_queries }.to hop("wait")
      end

      it "handles error" do
        query = instance_double(LanternDoctorQuery, servers: [server], db_name: "postgres", task_name: "test_query")
        expect(lantern_doctor).to receive(:queries).and_return([query])
        allow(sshable).to receive(:cmd).with("common/bin/daemonizer --check test_query").and_return("Failed")
        allow(sshable).to receive(:cmd).with("common/bin/daemonizer --logs test_query").and_return(JSON.generate({"stdout" => "error parse", "stderr" => "error"}))

        expect(query).to receive(:update_page_status).with("*", vm.name, true, nil, nil)
        expect(query).to receive(:update_page_status).with("*", vm.name, false, "error parse", "error")
        expect(query).to receive(:update).with(condition: "failed", last_checked: instance_of(Time))

        expect { nx.wait_queries }.to hop("wait")
      end

      it "handles failed queries" do
        query = instance_double(LanternDoctorQuery, servers: [server], db_name: "postgres", task_name: "test_query")
        expect(lantern_doctor).to receive(:queries).and_return([query])
        allow(sshable).to receive(:cmd).with("common/bin/daemonizer --check test_query").and_return("Failed")
        allow(sshable).to receive(:cmd).with("common/bin/daemonizer --logs test_query").and_return(JSON.generate({"stdout" => "", "stderr" => "error"}))

        expect(query).to receive(:update_page_status).with("*", vm.name, false, "", "error")
        expect(query).to receive(:update).with(condition: "failed", last_checked: instance_of(Time))

        expect { nx.wait_queries }.to hop("wait")
      end

      it "skips in progress" do
        query = instance_double(LanternDoctorQuery, servers: [server], db_name: "postgres", task_name: "test_query")
        expect(lantern_doctor).to receive(:queries).and_return([query])
        allow(sshable).to receive(:cmd).with("common/bin/daemonizer --check test_query").and_return("InProgress")

        expect { nx.wait_queries }.to hop("wait")
      end
    end
  end
end
