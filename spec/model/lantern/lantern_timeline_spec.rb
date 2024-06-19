# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe LanternTimeline do
  subject(:lantern_timeline) {
    described_class.new { _1.id = "c068cac7-ed45-82db-bf38-a003582b36ee" }
  }

  it "Shows bucket name" do
    expect(lantern_timeline.bucket_name).to eq("gs://#{Config.lantern_backup_bucket}/pvr1mcnhzd8p0qwwa00tr5cvex")
  end

  describe "#generate_walg_config" do
    it "generates walg config" do
      expect(lantern_timeline).to receive(:gcp_creds_b64).and_return("test-creds")
      config = {
        gcp_creds_b64: "test-creds",
        walg_gs_prefix: "gs://walg-dev-backups/pvr1mcnhzd8p0qwwa00tr5cvex"
      }

      expect(lantern_timeline.generate_walg_config).to eq(config)
    end
  end

  describe "#latest_restore_time" do
    it "returns current time" do
      diff = lantern_timeline.latest_restore_time - Time.now
      expect(diff < 1000).to be(true)
    end
  end

  describe "#need_backup?" do
    it "returns false for reader" do
      expect(lantern_timeline).to receive(:leader).and_return(nil)
      expect(lantern_timeline.need_backup?).to be(false)
    end

    it "returns false if already running" do
      leader = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("InProgress")
      expect(lantern_timeline).to receive(:leader).and_return(leader).at_least(:once)
      expect(lantern_timeline.need_backup?).to be(false)
    end

    it "returns true if not started" do
      leader = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("NotStarted")
      expect(lantern_timeline).to receive(:leader).and_return(leader).at_least(:once)
      expect(lantern_timeline.need_backup?).to be(true)
    end

    it "returns true if failed" do
      leader = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("Failed")
      expect(lantern_timeline).to receive(:leader).and_return(leader).at_least(:once)
      expect(lantern_timeline.need_backup?).to be(true)
    end

    it "returns true if last backup is nil" do
      leader = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("Succeeded").at_least(:once)
      expect(lantern_timeline).to receive(:leader).and_return(leader).at_least(:once)
      expect(lantern_timeline).to receive(:latest_backup_started_at).and_return(nil).at_least(:once)
      expect(lantern_timeline.need_backup?).to be(true)
    end

    it "returns true if last backup is more than a day ago" do
      leader = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("Succeeded").at_least(:once)
      expect(lantern_timeline).to receive(:leader).and_return(leader).at_least(:once)
      expect(lantern_timeline).to receive(:latest_backup_started_at).and_return(Time.now - 60 * 60 * 25).at_least(:once)
      expect(lantern_timeline.need_backup?).to be(true)
    end

    it "returns false if last backup is within a day" do
      leader = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("Succeeded").at_least(:once)
      expect(lantern_timeline).to receive(:leader).and_return(leader).at_least(:once)
      expect(lantern_timeline).to receive(:latest_backup_started_at).and_return(Time.now).at_least(:once)
      expect(lantern_timeline.need_backup?).to be(false)
    end
  end

  it "returns blob_storage_client" do
    allow(Hosting::GcpApis).to receive(:new).and_return(instance_double(Hosting::GcpApis))
    expect(lantern_timeline.blob_storage_client).not_to be_nil
  end

  describe "#backups" do
    it "returns backup list" do
      gcp_api = instance_double(Hosting::GcpApis)
      expect(gcp_api).to receive(:list_objects).with(Config.lantern_backup_bucket, "pvr1mcnhzd8p0qwwa00tr5cvex/basebackups_005/*_backup_stop_sentinel.json").and_return([{key: "1_backup_stop_sentinel.json"}, {key: "3_backup_stop_sentinel.json"}])
      expect(lantern_timeline).to receive(:blob_storage_client).and_return(gcp_api)
      expect(lantern_timeline.backups).to eq([{key: "1_backup_stop_sentinel.json"}, {key: "3_backup_stop_sentinel.json"}])
    end
  end

  describe "#backups_with_metadata" do
    it "returns backups with metadata about size" do
      gcp_api = instance_double(Hosting::GcpApis)
      expect(gcp_api).to receive(:list_objects).with(Config.lantern_backup_bucket, "pvr1mcnhzd8p0qwwa00tr5cvex/basebackups_005/*_backup_stop_sentinel.json").and_return([{key: "1_backup_stop_sentinel.json"}])
      expect(gcp_api).to receive(:get_json_object).with(Config.lantern_backup_bucket, "1_backup_stop_sentinel.json").and_return({"CompressedSize" => 10, "UncompressedSize" => 20})
      expect(lantern_timeline).to receive(:blob_storage_client).and_return(gcp_api).at_least(:once)
      expect(lantern_timeline.backups_with_metadata).to eq([{key: "1_backup_stop_sentinel.json", compressed_size: 10, uncompressed_size: 20}])
    end
  end

  describe "#latest_backup_label_before_target" do
    it "fails if no backup found" do
      expect(lantern_timeline).to receive(:backups).and_return([])

      expect { lantern_timeline.latest_backup_label_before_target(Time.now) }.to raise_error "BUG: no backup found"
    end

    it "returns latest backup label" do
      backups = [{last_modified: Time.now - 20 * 60, key: "#{lantern_timeline.ubid}/basebackups_005/1_backup_stop_sentinel.json"}, {last_modified: Time.now - 10 * 60, key: "#{lantern_timeline.ubid}/basebackups_005/2_backup_stop_sentinel.json"}]
      expect(lantern_timeline).to receive(:backups).and_return(backups)

      expect(lantern_timeline.latest_backup_label_before_target(Time.now)).to eq("2")
    end
  end

  describe "#refresh_earliest_backup_completion_time" do
    it "refreshes earliest backup time" do
      backups = [{last_modified: Time.now - 20 * 60, key: "basebackups_005/1_backup_stop_sentinel.json"}, {last_modified: Time.now - 10 * 60, key: "basebackups_005/2_backup_stop_sentinel.json"}]
      expect(lantern_timeline).to receive(:backups).and_return(backups)
      expect(lantern_timeline).to receive(:update).with({earliest_backup_completed_at: backups[0][:last_modified]})

      lantern_timeline.refresh_earliest_backup_completion_time
    end
  end

  describe "#earliest_restore_time" do
    it "returns earliest restore time" do
      earliest_restore = Time.now
      expect(lantern_timeline).to receive(:earliest_backup_completed_at).and_return(earliest_restore)
      expect(lantern_timeline.earliest_restore_time).to eq(earliest_restore + 5 * 60)
    end

    it "returns earliest restore time for e2e tests" do
      earliest_restore = Time.now
      expect(Config).to receive(:e2e_test?).and_return(true)
      expect(lantern_timeline).to receive(:earliest_backup_completed_at).and_return(earliest_restore)
      expect(lantern_timeline.earliest_restore_time).to eq(earliest_restore)
    end

    it "returns earliest restore time after refresh" do
      earliest_restore = Time.now
      expect(lantern_timeline).to receive(:refresh_earliest_backup_completion_time).and_return(earliest_restore)
      expect(lantern_timeline.earliest_restore_time).to eq(earliest_restore + 5 * 60)
    end

    it "returns nil" do
      expect(lantern_timeline).to receive(:refresh_earliest_backup_completion_time).and_return(nil)
      expect(lantern_timeline.earliest_restore_time).to be_nil
    end
  end

  describe "#get_backup_label" do
    it "slices bucket key correctly" do
      key = "#{lantern_timeline.ubid}/basebackups_005/1_backup_stop_sentinel.json"
      expect(lantern_timeline.get_backup_label(key)).to eq("1")
    end
  end

  describe "#take_backup" do
    it "creates new backup" do
      leader = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(lantern_timeline).to receive(:leader).and_return(leader)
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo lantern/bin/take_backup' take_postgres_backup")
      expect(lantern_timeline).to receive(:update)
      lantern_timeline.take_backup
    end
  end

  describe "#take_manual_backup" do
    it "fails if in progress" do
      leader = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(lantern_timeline).to receive(:leader).and_return(leader)
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("InProgress")
      expect {
        lantern_timeline.take_manual_backup
      }.to raise_error "Another backup is in progress please try again later"
    end

    it "creates page if more than 5 backups" do
      leader = instance_double(LanternServer, ubid: "test", vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(lantern_timeline).to receive(:leader).and_return(leader).at_least(:once)
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("NotStarted")
      backups = [
        {last_modified: Time.new},
        {last_modified: Time.new},
        {last_modified: Time.new},
        {last_modified: Time.new},
        {last_modified: Time.new},
        {last_modified: Time.new}
      ]
      expect(lantern_timeline).to receive(:backups).and_return(backups)
      expect(Prog::PageNexus).to receive(:assemble_with_logs)
      expect(lantern_timeline).to receive(:take_backup)
      expect(leader).to receive(:resource).and_return(instance_double(LanternResource, name: "test", ubid: "test")).at_least(:once)
      expect {
        lantern_timeline.take_manual_backup
      }.not_to raise_error
    end

    it "creates new backup" do
      leader = instance_double(LanternServer, ubid: "test", vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(lantern_timeline).to receive(:leader).and_return(leader).at_least(:once)
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("NotStarted")
      backups = [
        {last_modified: Time.new},
        {last_modified: Time.new},
        {last_modified: Time.new}
      ]
      expect(lantern_timeline).to receive(:backups).and_return(backups)
      expect(lantern_timeline).to receive(:take_backup)
      expect {
        lantern_timeline.take_manual_backup
      }.not_to raise_error
    end
  end

  describe "#need_cleanup?" do
    it "returns false for reader" do
      expect(lantern_timeline).to receive(:leader).and_return(nil)
      expect(lantern_timeline.need_cleanup?).to be(false)
    end

    it "returns false if already running" do
      leader = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check delete_old_backups").and_return("InProgress")
      expect(lantern_timeline).to receive(:leader).and_return(leader).twice
      expect(lantern_timeline.need_cleanup?).to be(false)
    end

    it "returns true if not started" do
      leader = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check delete_old_backups").and_return("NotStarted")
      expect(lantern_timeline).to receive(:leader).and_return(leader).twice
      expect(lantern_timeline.need_cleanup?).to be(true)
    end

    it "returns true if failed" do
      leader = instance_double(LanternServer, vm: instance_double(GcpVm, sshable: instance_double(Sshable)))
      expect(leader.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check delete_old_backups").and_return("Failed")
      expect(lantern_timeline).to receive(:leader).and_return(leader).twice
      expect(lantern_timeline.need_cleanup?).to be(true)
    end
  end

  describe "#last_checkpoint_file_exists?" do
    it "returns empty from query" do
      leader = instance_double(LanternServer)
      expect(lantern_timeline).to receive(:leader).and_return(leader).at_least(:once)
      expect(leader).to receive(:run_query).and_return("")
      expect(lantern_timeline.last_checkpoint_file_exists?).to be(true)
    end

    it "returns no backups" do
      leader = instance_double(LanternServer)
      expect(lantern_timeline).to receive(:leader).and_return(leader).at_least(:once)
      expect(leader).to receive(:run_query).and_return("000000010000000000000072")
      gcp_api = instance_double(Hosting::GcpApis)
      expect(gcp_api).to receive(:list_objects).with(Config.lantern_backup_bucket, "pvr1mcnhzd8p0qwwa00tr5cvex/wal_005/000000010000000000000072.lz4").and_return([])
      expect(lantern_timeline).to receive(:blob_storage_client).and_return(gcp_api)

      expect(lantern_timeline.last_checkpoint_file_exists?).to be(false)
    end

    it "returns backup file" do
      leader = instance_double(LanternServer)
      expect(lantern_timeline).to receive(:leader).and_return(leader).at_least(:once)
      expect(leader).to receive(:run_query).and_return("000000010000000000000072")
      gcp_api = instance_double(Hosting::GcpApis)
      expect(gcp_api).to receive(:list_objects).with(Config.lantern_backup_bucket, "pvr1mcnhzd8p0qwwa00tr5cvex/wal_005/000000010000000000000072.lz4").and_return([{}])
      expect(lantern_timeline).to receive(:blob_storage_client).and_return(gcp_api)

      expect(lantern_timeline.last_checkpoint_file_exists?).to be(true)
    end
  end
end
