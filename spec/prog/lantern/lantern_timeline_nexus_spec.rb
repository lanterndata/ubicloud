# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Lantern::LanternTimelineNexus do
  subject(:nx) { described_class.new(Strand.create(id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0", prog: "Lantern::LanternTimelineNexus", label: "start")) }

  let(:sshable) { instance_double(Sshable) }

  let(:timeline) {
    instance_double(
      LanternTimeline,
      ubid: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
      id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
      gcp_creds_b64: "test-creds",
      service_account_name: "test-sa",
      bucket_name: "test-bucket",
      parent: nil
    )
  }

  let(:lantern_server) {
    instance_double(
      LanternServer,
      ubid: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
      vm: instance_double(
        GcpVm,
        id: "104b0033-b3f6-8214-ae27-0cd3cef18ce4",
        sshable: sshable
      ),
      timeline: timeline
    )
  }

  before do
    allow(nx).to receive(:lantern_timeline).and_return(lantern_server.timeline)
  end

  describe ".assemble" do
    it "fails to create lantern timeline if no parent found" do
      expect {
        described_class.assemble(
          parent_id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0"
        )
      }.to raise_error "No existing parent"
    end

    it "creates lantern timeline without parent" do
      st = described_class.assemble
      timeline = LanternTimeline[st.id]
      expect(timeline.gcp_creds_b64).to be_nil
    end
  end

  describe "#start" do
    it "hops to wait leader" do
      api = instance_double(Hosting::GcpApis)
      allow(api).to receive(:create_service_account).and_return({"email" => "sa-email"})
      allow(api).to receive(:export_service_account_key).with("sa-email").and_return("gcp-creds")
      allow(api).to receive(:allow_bucket_usage_by_prefix)
      allow(Hosting::GcpApis).to receive(:new).and_return(api)

      allow(timeline).to receive(:update).with({service_account_name: "sa-email", gcp_creds_b64: "gcp-creds"})

      expect { nx.start }.to hop("wait_leader")
    end
  end

  describe "#wait_leader" do
    it "hops to destroy if no leader" do
      expect(lantern_server.timeline).to receive(:leader).and_return(nil)
      expect { nx.wait_leader }.to hop("destroy")
    end

    it "naps if leader is not available" do
      expect(lantern_server.timeline).to receive(:leader).and_return(lantern_server).twice
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "creating"))
      expect { nx.wait_leader }.to nap(5)
    end

    it "hops to wait" do
      expect(lantern_server.timeline).to receive(:leader).and_return(lantern_server).twice
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect { nx.wait_leader }.to hop("wait")
    end
  end

  describe "#wait" do
    it "hops to take_backup if needs backup" do
      expect(lantern_server.timeline).to receive(:need_backup?).and_return(true)
      expect { nx.wait }.to hop("take_backup")
    end

    it "hops to delete_old_backups if needs cleanup" do
      expect(lantern_server.timeline).to receive(:need_backup?).and_return(false)
      expect(lantern_server.timeline).to receive(:need_cleanup?).and_return(true)
      expect(timeline).to receive(:leader).and_return(lantern_server)
      (Time.new - (24 * 60 * 60 * Config.backup_retention_days)).strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      expect(lantern_server.vm.sshable).to receive(:cmd).with(a_string_matching("common/bin/daemonizer 'docker compose -f /var/lib/lantern/docker-compos.yaml exec -T -u root postgresql bash -c"))
      expect(lantern_server.timeline).to receive(:backups).and_return([{last_modified: Time.now - 1 * 24 * 60 * 60}])
      expect(lantern_server.timeline).to receive(:leader).and_return(lantern_server)
      expect { nx.wait }.to nap(20 * 60)
    end

    it "puts missing backup error for 2 days" do
      expect(lantern_server.timeline).to receive(:need_backup?).and_return(false)
      expect(lantern_server.timeline).to receive(:need_cleanup?).and_return(false)
      expect(lantern_server.timeline).to receive(:backups).and_return([{last_modified: Time.now - 3 * 24 * 60 * 60}])
      expect(lantern_server.timeline).to receive(:leader).and_return(lantern_server)
      expect(lantern_server.timeline).to receive(:ubid).and_return(lantern_server.timeline.id)
      expect { nx.wait }.to nap(20 * 60)
      expect(Page.first).not_to be_nil
    end

    it "puts missing backup for less than 2 days" do
      expect(lantern_server.timeline).to receive(:need_backup?).and_return(false)
      expect(lantern_server.timeline).to receive(:need_cleanup?).and_return(false)
      expect(lantern_server.timeline).to receive(:backups).and_return([{last_modified: Time.now - 1 * 24 * 60 * 60}])
      expect(lantern_server.timeline).to receive(:leader).and_return(lantern_server)
      expect { nx.wait }.to nap(20 * 60)
      expect(Page.first).to be_nil
    end

    it "puts missing backup days if no leader" do
      expect(lantern_server.timeline).to receive(:need_backup?).and_return(false)
      expect(lantern_server.timeline).to receive(:need_cleanup?).and_return(false)
      expect(lantern_server.timeline).to receive(:backups).and_return([])
      expect(lantern_server.timeline).to receive(:leader).and_return(nil)
      expect(lantern_server.timeline).to receive(:created_at).and_return(Time.now - 1 * 24 * 60 * 60)
      page = instance_double(Page)
      expect(Page).to receive(:from_tag_parts).and_return(page)
      expect(page).to receive(:incr_resolve)
      expect { nx.wait }.to nap(20 * 60)
      expect(Page.first).to be_nil
    end
  end

  describe "#take_backup" do
    it "hops to wait if no need to backup" do
      expect(lantern_server.timeline).to receive(:need_backup?).and_return(false)
      expect { nx.take_backup }.to hop("wait")
    end

    it "calls backup command" do
      expect(lantern_server.timeline).to receive(:need_backup?).and_return(true)
      expect(lantern_server.timeline).to receive(:take_backup)
      expect { nx.take_backup }.to hop("wait")
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

  describe "#destroy" do
    it "removes parent from children and exit with message" do
      expect(lantern_server.timeline).to receive(:destroy)
      child = instance_double(LanternTimeline, parent_id: "test")
      children = [child]
      api = instance_double(Hosting::GcpApis)
      allow(api).to receive(:remove_service_account)
      allow(Hosting::GcpApis).to receive(:new).and_return(api)
      expect(child).to receive(:parent_id=).with(nil)
      expect(child).to receive(:save_changes)
      expect(lantern_server.timeline).to receive(:children).and_return(children).twice
      expect { nx.destroy }.to exit({"msg" => "lantern timeline is deleted"})
    end

    it "exits with message without deleting sa" do
      expect(lantern_server.timeline).to receive(:destroy)
      expect(lantern_server.timeline).to receive(:children).and_return([])
      expect(lantern_server.timeline).to receive(:service_account_name).and_return(nil)
      expect { nx.destroy }.to exit({"msg" => "lantern timeline is deleted"})
    end

    it "exits with message" do
      api = instance_double(Hosting::GcpApis)
      allow(api).to receive(:remove_service_account)
      allow(Hosting::GcpApis).to receive(:new).and_return(api)
      expect(lantern_server.timeline).to receive(:destroy)
      expect(lantern_server.timeline).to receive(:children).and_return([])
      expect { nx.destroy }.to exit({"msg" => "lantern timeline is deleted"})
    end
  end
end
