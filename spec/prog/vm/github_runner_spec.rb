# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"
require "octokit"

RSpec.describe Prog::Vm::GithubRunner do
  subject(:nx) {
    described_class.new(Strand.new).tap {
      _1.instance_variable_set(:@github_runner, github_runner)
    }
  }

  let(:github_runner) {
    GithubRunner.new(installation_id: "", repository_name: "test-repo", label: "ubicloud", ready_at: Time.now).tap {
      _1.id = GithubRunner.generate_uuid
    }
  }

  let(:vm) {
    Vm.new(family: "standard", cores: 1, name: "dummy-vm", location: "hetzner-hel1")
  }
  let(:sshable) { instance_double(Sshable) }
  let(:client) { instance_double(Octokit::Client) }

  before do
    allow(Github).to receive(:installation_client).and_return(client)
    allow(github_runner).to receive_messages(vm: vm, installation: instance_double(GithubInstallation, installation_id: 123))
    allow(vm).to receive(:sshable).and_return(sshable)
  end

  describe ".assemble" do
    it "creates github runner and vm with sshable" do
      project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      installation = GithubInstallation.create_with_id(installation_id: 123, project_id: project.id, name: "test-user", type: "User")

      st = nil
      expect {
        st = described_class.assemble(installation, repository_name: "test-repo", label: "ubicloud")
      }.to output("Project[#{project.ubid}] Pool is empty for ubicloud, creating a new VM\n").to_stdout

      runner = GithubRunner[st.id]
      expect(runner).not_to be_nil
      expect(runner.repository_name).to eq("test-repo")
      expect(runner.vm.unix_user).to eq("runner")
      expect(runner.vm.sshable.unix_user).to eq("runner")
    end

    it "creates github runner with custom size" do
      project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      installation = GithubInstallation.create_with_id(installation_id: 123, project_id: project.id, name: "test-user", type: "User")
      st = nil
      expect {
        st = described_class.assemble(installation, repository_name: "test-repo", label: "ubicloud-standard-8")
      }.to output("Project[#{project.ubid}] Pool is empty for ubicloud-standard-8, creating a new VM\n").to_stdout

      runner = GithubRunner[st.id]
      expect(runner).not_to be_nil
      expect(runner.repository_name).to eq("test-repo")
      expect(runner.vm.unix_user).to eq("runner")
      expect(runner.vm.family).to eq("standard")
      expect(runner.vm.cores).to eq(4)
      expect(runner.vm.sshable.unix_user).to eq("runner")
    end

    it "fails if label is not valid" do
      expect {
        described_class.assemble(instance_double(GithubInstallation), repository_name: "test-repo", label: "ubicloud-standard-1")
      }.to raise_error RuntimeError, "Invalid GitHub runner label: ubicloud-standard-1"
    end
  end

  describe ".pick_vm" do
    it "provisions a VM if the pool is not existing" do
      project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      expect(VmPool).to receive(:where).and_return([])
      expect(Prog::Vm::Nexus).to receive(:assemble).and_call_original
      vm = nil
      expect {
        vm = described_class.pick_vm("ubicloud-standard-4", project)
      }.to output("Project[#{project.ubid}] Pool is empty for ubicloud-standard-4, creating a new VM\n").to_stdout
      expect(vm).not_to be_nil
      expect(vm.sshable.unix_user).to eq("runner")
      expect(vm.family).to eq("standard")
      expect(vm.cores).to eq(2)
    end

    it "provisions a new vm if pool is valid but there is no vm" do
      project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      git_runner_pool = VmPool.create_with_id(size: 2, vm_size: "standard-4", boot_image: "github-ubuntu-2204", location: "github-runners")
      expect(VmPool).to receive(:where).with(vm_size: "standard-4", boot_image: "github-ubuntu-2204", location: "github-runners").and_return([git_runner_pool])
      expect(git_runner_pool).to receive(:pick_vm).and_return(nil)
      expect(Prog::Vm::Nexus).to receive(:assemble).and_call_original
      vm = nil
      expect {
        vm = described_class.pick_vm("ubicloud-standard-4", project)
      }.to output("Project[#{project.ubid}] Pool is empty for ubicloud-standard-4, creating a new VM\n").to_stdout
      expect(vm).not_to be_nil
      expect(vm.sshable.unix_user).to eq("runner")
      expect(vm.family).to eq("standard")
      expect(vm.cores).to eq(2)
    end

    it "uses the existing vm if pool can pick one" do
      project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      git_runner_pool = VmPool.create_with_id(size: 2, vm_size: "standard-4", boot_image: "github-ubuntu-2204", location: "github-runners")
      expect(VmPool).to receive(:where).with(vm_size: "standard-4", boot_image: "github-ubuntu-2204", location: "github-runners").and_return([git_runner_pool])
      expect(git_runner_pool).to receive(:pick_vm).and_return(vm)

      ps = instance_double(PrivateSubnet)
      expect(vm).to receive(:private_subnets).and_return([ps])
      expect(ps).to receive(:associate_with_project).with(project).and_return(true)
      expect(vm).to receive(:associate_with_project).with(project).and_return(true)
      expect(BillingRecord).to receive(:create_with_id).and_return(nil)
      expect(BillingRecord).to receive(:create_with_id).and_return(nil)
      adr = instance_double(AssignedVmAddress, id: "id", ip: "1.1.1.1")
      expect(vm).to receive(:assigned_vm_address).and_return(adr).at_least(:once)
      vm = nil
      expect {
        vm = described_class.pick_vm("ubicloud-standard-4", project)
      }.to output("Project[#{project.ubid}] Pool is used for ubicloud-standard-4\n").to_stdout
      expect(vm).not_to be_nil
      expect(vm.name).to eq("dummy-vm")
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if already in the wait_vm_destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("wait_vm_destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "naps if vm not ready" do
      expect(vm).to receive(:strand).and_return(Strand.new(label: "prep"))
      expect { nx.start }.to nap(5)
    end

    it "update sshable host and hops" do
      expect(vm).to receive(:strand).and_return(Strand.new(label: "wait"))
      expect(vm).to receive(:ephemeral_net4).and_return("1.1.1.1")
      expect(sshable).to receive(:update).with(host: "1.1.1.1")
      expect { nx.start }.to hop("setup_environment")
    end
  end

  it "hops to install_actions_runner" do
    expect(nx).to receive(:install_ssh_listen_only_nftables_chain)
    expect(sshable).to receive(:cmd).with("sudo usermod -a -G docker,adm,systemd-journal runner")
    expect(sshable).to receive(:cmd).with(/\/opt\/post-generation/)
    expect(sshable).to receive(:invalidate_cache_entry)
    expect(sshable).to receive(:cmd).with("sudo mv /usr/local/share/actions-runner ./")
    expect(sshable).to receive(:cmd).with("sudo chown -R runner:runner actions-runner")
    expect(sshable).to receive(:cmd).with("./actions-runner/env.sh")
    expect(sshable).to receive(:cmd).with("echo \"PATH=$PATH\" >> ./actions-runner/.env")

    expect { nx.setup_environment }.to hop("register_runner")
  end

  describe "#register_runner" do
    it "generates runner if not runner id not set and hops" do
      expect(github_runner).to receive(:runner_id).and_return(nil)
      expect(client).to receive(:post).with(/.*generate-jitconfig/, hash_including(name: github_runner.ubid.to_s, labels: [github_runner.label])).and_return({runner: {id: 123}, encoded_jit_config: "AABBCC"})
      expect(sshable).to receive(:cmd).with("sudo systemd-run --uid runner --gid runner --working-directory '/home/runner' --unit runner-script --remain-after-exit -- ./actions-runner/run.sh --jitconfig AABBCC")
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(github_runner).to receive(:update).with(runner_id: 123, ready_at: anything)

      expect { nx.register_runner }.to hop("wait")
    end

    it "does not generate runner if runner exists and destroys it" do
      expect(github_runner).to receive(:runner_id).and_return(123).at_least(:once)
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("failed")
      expect(client).to receive(:delete)
      expect(github_runner).to receive(:update).with(runner_id: nil, ready_at: nil)

      expect { nx.register_runner }.to nap(10)
    end

    it "naps if script return unknown status" do
      expect(github_runner).to receive(:runner_id).and_return(123).at_least(:once)
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("unknown")

      expect { nx.register_runner }.to nap(10)
    end
  end

  describe "#wait" do
    it "does not destroy runner if it does not pick a job in two minutes, and busy" do
      expect(Time).to receive(:now).and_return(github_runner.ready_at + 3 * 60)
      expect(client).to receive(:get).and_return({busy: true})
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(github_runner).not_to receive(:incr_destroy)

      expect { nx.wait }.to nap(15)
    end

    it "destroys runner if it does not pick a job in two minutes and not busy" do
      expect(github_runner).to receive(:job_id).and_return(nil)
      expect(Time).to receive(:now).and_return(github_runner.ready_at + 3 * 60)
      expect(client).to receive(:get).and_return({busy: false})
      expect(github_runner).to receive(:incr_destroy)

      expect do
        expect { nx.wait }.to nap(0)
      end.to output("GithubRunner[#{github_runner.ubid}] Not pick a job in two minutes, destroying it\n").to_stdout
    end

    it "does not destroy runner if it doesn not pick a job but two minutes not pass yet" do
      expect(github_runner).to receive(:job_id).and_return(nil)
      expect(Time).to receive(:now).and_return(github_runner.ready_at + 1 * 60)
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")
      expect(github_runner).not_to receive(:incr_destroy)

      expect { nx.wait }.to nap(15)
    end

    it "destroys runner if runner-script exited with Succeeded" do
      expect(github_runner).to receive(:job_id).and_return(123)
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("exited")
      expect(github_runner).to receive(:incr_destroy)

      expect { nx.wait }.to nap(0)
    end

    it "naps" do
      expect(github_runner).to receive(:job_id).and_return(123)
      expect(sshable).to receive(:cmd).with("systemctl show -p SubState --value runner-script").and_return("running")

      expect { nx.wait }.to nap(15)
    end
  end

  describe "#destroy" do
    it "naps if runner not deregistered yet" do
      expect(client).to receive(:get)
      expect(client).to receive(:delete)

      expect { nx.destroy }.to nap(5)
    end

    it "destroys resources and hops if runner deregistered" do
      expect(nx).to receive(:register_deadline)
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(client).not_to receive(:delete)
      expect(sshable).to receive(:destroy)
      expect(vm).to receive(:incr_destroy)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end

    it "does not destroy vm if it's already destroyed" do
      expect(nx).to receive(:register_deadline)
      expect(nx).to receive(:decr_destroy)
      expect(client).to receive(:get).and_raise(Octokit::NotFound)
      expect(client).not_to receive(:delete)
      expect(github_runner).to receive(:vm).and_return(nil)
      expect(sshable).not_to receive(:destroy)
      expect(vm).not_to receive(:incr_destroy)

      expect { nx.destroy }.to hop("wait_vm_destroy")
    end
  end

  describe "#wait_vm_destroy" do
    it "naps if vm not destroyed yet" do
      expect { nx.wait_vm_destroy }.to nap(10)
    end

    it "pops if vm destroyed" do
      expect(nx).to receive(:vm).and_return(nil)
      expect(github_runner).to receive(:destroy)

      expect { nx.wait_vm_destroy }.to exit({"msg" => "github runner deleted"})
    end
  end

  describe "nftables" do
    let(:ip_netns_detail_json_fixture) do
      <<JSON
[
  {
    "ifindex": 1,
    "ifname": "lo",
    "flags": [
      "LOOPBACK"
    ],
    "mtu": 65536,
    "qdisc": "noop",
    "operstate": "DOWN",
    "linkmode": "DEFAULT",
    "group": "default",
    "txqlen": 1000,
    "link_type": "loopback",
    "address": "00:00:00:00:00:00",
    "broadcast": "00:00:00:00:00:00",
    "promiscuity": 0,
    "min_mtu": 0,
    "max_mtu": 0,
    "inet6_addr_gen_mode": "eui64",
    "num_tx_queues": 1,
    "num_rx_queues": 1,
    "gso_max_size": 65536,
    "gso_max_segs": 65535
  },
  {
    "ifindex": 2,
    "link_index": 3,
    "ifname": "vethivmezdgrk",
    "flags": [
      "BROADCAST",
      "MULTICAST",
      "UP",
      "LOWER_UP"
    ],
    "mtu": 1500,
    "qdisc": "noqueue",
    "operstate": "UP",
    "linkmode": "DEFAULT",
    "group": "default",
    "txqlen": 1000,
    "link_type": "ether",
    "address": "76:91:b2:bd:d0:d3",
    "broadcast": "ff:ff:ff:ff:ff:ff",
    "link_netnsid": 0,
    "promiscuity": 0,
    "min_mtu": 68,
    "max_mtu": 65535,
    "linkinfo": {
      "info_kind": "veth"
    },
    "inet6_addr_gen_mode": "eui64",
    "num_tx_queues": 8,
    "num_rx_queues": 8,
    "gso_max_size": 65536,
    "gso_max_segs": 65535
  },
  {
    "ifindex": 3,
    "ifname": "nc1sww90p6",
    "flags": [
      "BROADCAST",
      "MULTICAST",
      "UP",
      "LOWER_UP"
    ],
    "mtu": 1500,
    "qdisc": "fq_codel",
    "operstate": "UP",
    "linkmode": "DEFAULT",
    "group": "default",
    "txqlen": 1000,
    "link_type": "ether",
    "address": "8a:5d:4a:ba:86:5f",
    "broadcast": "ff:ff:ff:ff:ff:ff",
    "promiscuity": 0,
    "min_mtu": 68,
    "max_mtu": 65521,
    "linkinfo": {
      "info_kind": "tun",
      "info_data": {
        "type": "tap",
        "pi": false,
        "vnet_hdr": true,
        "multi_queue": false,
        "persist": true,
        "user": "vmezdgrk"
      }
    },
    "inet6_addr_gen_mode": "eui64",
    "num_tx_queues": 1,
    "num_rx_queues": 1,
    "gso_max_size": 65536,
    "gso_max_segs": 65535
  }
]
JSON
    end

    it "computes all host-routed mac addresses" do
      host_ssh = instance_double(Sshable)
      expect(nx.vm).to receive(:vm_host).and_return(instance_double(VmHost, sshable: host_ssh)).at_least(:once)
      expect(host_ssh).to receive(:cmd).with(
        "sudo -- ip --detail --json --netns 00000000 link"
      ).and_return(ip_netns_detail_json_fixture)

      expect(nx.vm.vm_host).to receive(:sshable).and_return(host_ssh)
      expect(nx.tun_mac_addresses).to eq ["8a:5d:4a:ba:86:5f"]
    end

    it "can run a command to install an nft chain" do
      expect(nx).to receive(:template_ssh_only_listen_nftable_conf).and_return("bogus sample nftables conf")
      expect(nx.vm.sshable).to receive(:cmd).with("sudo nft --file -", stdin: "bogus sample nftables conf")
      nx.install_ssh_listen_only_nftables_chain
    end

    it "templates a nftables conf" do
      expect(nx).to receive(:tun_mac_addresses).and_return(["8a:5d:4a:ba:86:5f"])
      expect(nx.template_ssh_only_listen_nftable_conf).to eq <<TEMPLATED
# An nftables idiom for idempotent re-create of a named entity: merge
# in an empty table (a no-op if the table already exists) and then
# delete, before creating with a new definition.
table inet clover_github_actions;
delete table inet clover_github_actions;

table inet clover_github_actions {
  chain input {
    type filter hook input priority 0;

    # If a conntrack has been instantiated for a flow, allow the
    # packet through.

    # The trick in the rest of all this is to allow only the
    # current host to initiate the creation of entries in the
    # conntrack table, and they cannot be initiated from other
    # hosts on the Internet, with a notable exception for SSH.
    ct state vmap { established : accept, related : accept, invalid : drop }

    # Needed for neighbor solicitation at least to establish new
    # connections on IPv6, including DNS queries to IPv6 servers,
    # but on consideration of the goal of blocking attacks on
    # vulnerable GitHub Action payloads, it's okay to enable the
    # full ICMP suite for IPv4 and IPv6.
    meta l4proto { icmp, icmpv6 } accept

    # An exception to the "no connections initiated from the
    # Internet" rule, allow port 22/SSH to receive packets from the
    # internet without a conntrack state already established.
    # This is how Clover connects and controls the runner, so it's
    # obligatory.
    tcp dport 22 accept

    # Allow all other traffic that doesn't come from the host
    # forwarding, e.g. between interfaces on the system, as in
    # some uses of containers.  Our control over that is limited,
    # we want to not be debugging our interactions with GitHub's
    # pretty involved definition if we can avoid it.  Thus,
    # correlating it with a feature of the host's routing is one
    # way to narrowly define the behavior we want.
    ether saddr != {"8a:5d:4a:ba:86:5f"} accept

    # Finally, if passing no other conditions, drop all traffic
    # that comes from the host router hop.
    ether saddr {"8a:5d:4a:ba:86:5f"} drop
  }
}
TEMPLATED
    end
  end
end
