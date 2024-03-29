# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Lantern::LanternServerNexus do
  subject(:nx) { described_class.new(Strand.create(id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0", prog: "Lantern::LanternServerNexus", label: "start")) }

  let(:sshable) { instance_double(Sshable) }

  let(:lantern_server) {
    instance_double(
      LanternServer,
      ubid: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
      gcp_vm: instance_double(
        GcpVm,
        id: "104b0033-b3f6-8214-ae27-0cd3cef18ce4",
        sshable: sshable,
        domain: nil
      )
    )
  }

  before do
    allow(nx).to receive(:lantern_server).and_return(lantern_server)
  end

  describe ".assemble" do
    it "creates lantern server and vm with sshable" do
      postgres_project = Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }

      st = described_class.assemble(
        project_id: postgres_project.id,
        lantern_version: "0.2.0",
        extras_version: "0.1.3",
        minor_version: "2",
        org_id: 0,
        name: "instance-test",
        instance_type: "writer",
        db_name: "testdb",
        target_vm_size: "standard-2",
        db_user: "test",
        app_env: "test",
        db_user_password: "test-pass",
        postgres_password: "test-pg-pass",
        repl_password: "test-repl-pass",
        enable_telemetry: true,
        enable_debug: true,
      )
      lantern_server = LanternServer[st.id]
      expect(lantern_server).not_to be_nil
      expect(lantern_server.gcp_vm).not_to be_nil
      expect(lantern_server.gcp_vm.sshable).not_to be_nil

      expect(lantern_server.app_env).to eq("test")
      expect(lantern_server.db_user).to eq("test")
      expect(lantern_server.db_user_password).to eq("test-pass")
      expect(lantern_server.postgres_password).to eq("test-pg-pass")
      expect(lantern_server.repl_password).to eq("test-repl-pass")
      expect(lantern_server.enable_telemetry).to eq(true)
      expect(lantern_server.debug).to eq(true)
      expect(lantern_server.lantern_version).to eq("0.2.0")
      expect(lantern_server.extras_version).to eq("0.1.3")
      expect(lantern_server.minor_version).to eq("2")
      expect(lantern_server.org_id).to eq(0)
      expect(lantern_server.name).to eq("instance-test")
      expect(lantern_server.instance_type).to eq("writer")
      expect(lantern_server.db_name).to eq("testdb")
      expect(lantern_server.db_user).to eq("test")
      expect(lantern_server.gcp_vm.cores).to eq(2)
    end
  end

  describe "#start" do
    it "naps if vm not ready" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "prep"))
      expect { nx.start }.to nap(5)
    end

    it "update sshable host and hops" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(lantern_server).to receive(:incr_initial_provisioning)
      expect { nx.start }.to hop("bootstrap_rhizome")
    end

    describe "#bootstrap_rhizome" do
      it "buds a bootstrap rhizome process" do
        expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "lantern", "subject_id" => lantern_server.gcp_vm.id, "user" => "lantern"})
        expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
      end
    end

    describe "#wait_bootstrap_rhizome" do
      before { expect(nx).to receive(:reap) }

      it "hops to setup_docker_stack if there are no sub-programs running" do
        expect(nx).to receive(:leaf?).and_return true

        expect { nx.wait_bootstrap_rhizome }.to hop("setup_docker_stack")
      end

      it "donates if there are sub-programs running" do
        expect(nx).to receive(:leaf?).and_return false
        expect(nx).to receive(:donate).and_call_original

        expect { nx.wait_bootstrap_rhizome }.to nap(0)
      end
    end

    describe "#setup_docker_stack" do
      it "Calls add_domain if gcp_vm has domain after setup_docker_stack" do
        allow(lantern_server).to receive(:org_id)
        allow(lantern_server).to receive(:name)
        allow(lantern_server).to receive(:instance_type)
        allow(lantern_server).to receive(:db_name)
        allow(lantern_server).to receive(:db_user)
        allow(lantern_server).to receive(:db_user_password)
        allow(lantern_server).to receive(:postgres_password)
        allow(lantern_server).to receive(:master_host)
        allow(lantern_server).to receive(:master_port)
        allow(lantern_server).to receive(:lantern_version)
        allow(lantern_server).to receive(:extras_version)
        allow(lantern_server).to receive(:minor_version)
        allow(lantern_server).to receive(:app_env)
        allow(lantern_server).to receive(:debug)
        allow(lantern_server).to receive(:enable_telemetry)
        allow(lantern_server).to receive(:repl_password)
        allow(lantern_server).to receive(:repl_user)
        allow(lantern_server.gcp_vm.sshable).to receive(:cmd).and_return(nil)
        expect(lantern_server.gcp_vm).to receive(:domain).and_return "test.lantern.dev"
        expect(lantern_server).to receive(:incr_add_domain) do || nx.incr_add_domain end
        expect { nx.setup_docker_stack }.to hop("wait_db_available")
        expect(nx).to receive(:available?).and_return(true)
        expect { nx.wait_db_available }.to hop("wait")
        expect { nx.wait }.to hop("add_domain")
      end
    end
  end

  describe "#update_lantern_extension" do
    it "should update lantern extension" do
      allow(lantern_server).to receive(:update)
      allow(lantern_server).to receive(:incr_update_lantern_extension)
      lantern_server.update(lantern_version: "0.2.0")
      nx.incr_update_rhizome
      nx.incr_update_lantern_extension
      expect { nx.wait }.to hop("update_rhizome")
      expect { nx.wait_update_rhizome }.to hop("update_lantern_extension")
    end

    it "should update lantern_extras extension" do
      allow(lantern_server).to receive(:update)
      allow(lantern_server).to receive(:incr_update_extras_extension)
      lantern_server.update(lantern_version: "0.1.1")
      nx.incr_update_rhizome
      nx.incr_update_extras_extension
      expect { nx.wait }.to hop("update_rhizome")
      expect { nx.wait_update_rhizome }.to hop("update_extras_extension")
    end

    it "should update container image" do
      allow(lantern_server).to receive(:update)
      allow(lantern_server).to receive(:incr_update_image)
      lantern_server.update(lantern_version: "0.1.1", minor_version: "2")
      nx.incr_update_rhizome
      nx.incr_update_image
      expect { nx.wait }.to hop("update_rhizome")
      expect { nx.wait_update_rhizome }.to hop("update_image")
    end

    it "should add domain and setup ssl" do
      allow(lantern_server).to receive(:update)
      allow(lantern_server).to receive(:incr_add_domain)
      lantern_server.update(domain: "test.lantern.dev")
      nx.incr_add_domain
      expect { nx.wait }.to hop("add_domain")
      expect(lantern_server.gcp_vm.sshable).to receive(:host).and_return("1.1.1.1")
      stub_request(:get, "https://api.cloudflare.com/client/v4/zones/test/dns_records?name").to_return(status: 200, body: JSON.dump({:result => []}), headers: {})
      stub_request(:post, "https://api.cloudflare.com/client/v4/zones/test/dns_records")
        .with(
          body: "{\"content\":\"1.1.1.1\",\"name\":null,\"proxied\":false,\"type\":\"A\",\"comment\":\"dns record for lantern cloud db\",\"ttl\":60}",
          headers: {
            'Authorization' => 'Bearer test-token',
            'Content-Type' => 'application/json',
            'Host' => 'api.cloudflare.com:443'
          }
        )
        .to_return(status: 200, body: "", headers: {})
      expect { nx.add_domain }.to hop("setup_ssl")
    end
  end
end
