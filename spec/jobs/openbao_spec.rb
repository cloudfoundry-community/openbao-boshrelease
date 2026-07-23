require 'rspec'
require 'json'
require 'bosh/template/test'
require 'yaml'

describe 'openbao' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '../..')) }
  let(:job) { release.job('openbao') }
  let(:properties) { {} }

  def make_links(count)
    instances = (1..count).map do |i|
      Bosh::Template::Test::LinkInstance.new(address: "10.0.0.#{i}")
    end
    [Bosh::Template::Test::Link.new(name: 'openbao', instances: instances)]
  end

  let(:links_3_node) { make_links(3) }
  let(:links_1_node) { make_links(1) }

  # Instance spec with address matching a link instance, so the template's
  # `next if ip == spec.address` self-exclusion filter works correctly.
  let(:spec_node1) { Bosh::Template::Test::InstanceSpec.new(ip: '10.0.0.1', address: '10.0.0.1') }
  let(:spec_standalone) { Bosh::Template::Test::InstanceSpec.new(ip: '10.0.0.1', address: '10.0.0.1') }

  # ── config/openbao.hcl ──

  context 'config/openbao.hcl' do
    let(:template) { job.template('config/openbao.hcl') }

    context 'with defaults and 3-node cluster' do
      let(:rendered) { template.render(properties, spec: spec_node1, consumes: links_3_node) }

      it 'binds to port 443' do
        expect(rendered).to include('0.0.0.0:443')
      end

      it 'disables ui by default' do
        expect(rendered).to include('ui = false')
      end

      it 'sets default lease TTL to 768h' do
        expect(rendered).to include('default_lease_ttl = "768h"')
      end

      it 'sets max lease TTL to 768h' do
        expect(rendered).to include('max_lease_ttl     = "768h"')
      end

      it 'generates 2 retry_join blocks for a 3-node cluster' do
        expect(rendered.scan('retry_join {').length).to eq(2)
      end

      it 'uses HTTPS scheme in api_addr' do
        expect(rendered).to match(/api_addr\s+=\s+"https:\/\//)
      end

      it 'uses HTTPS scheme in retry_join leader_api_addr' do
        expect(rendered).to match(/leader_api_addr\s+=\s+"https:\/\//)
      end

      it 'uses raft storage' do
        expect(rendered).to include('storage "raft"')
      end

      it 'sets raft storage path' do
        expect(rendered).to include('/var/vcap/store/openbao/raft')
      end

      it 'uses spec.id for node_id' do
        expect(rendered).to match(/node_id\s+=\s+"/)
      end

      it 'sets TLS min version to tls12' do
        expect(rendered).to include('tls_min_version = "tls12"')
      end

      it 'includes leader_ca_cert_file in retry_join' do
        expect(rendered).to include('leader_ca_cert_file')
      end

      it 'includes leader_client_cert_file by default' do
        expect(rendered).to include('leader_client_cert_file')
      end

      it 'includes leader_client_key_file by default' do
        expect(rendered).to include('leader_client_key_file')
      end
    end

    context 'with custom port' do
      let(:properties) { { 'openbao' => { 'port' => 8200 } } }
      let(:rendered) { template.render(properties, spec: spec_node1, consumes: links_3_node) }

      it 'binds to custom port in listener' do
        expect(rendered).to include('0.0.0.0:8200')
      end

      it 'uses custom port in api_addr' do
        expect(rendered).to match(/api_addr.*:8200"/)
      end

      it 'uses custom port in retry_join' do
        expect(rendered).to match(/leader_api_addr.*:8200"/)
      end
    end

    context 'with UI enabled' do
      let(:properties) { { 'openbao' => { 'ui' => true } } }
      let(:rendered) { template.render(properties, spec: spec_node1, consumes: links_3_node) }

      it 'enables ui' do
        expect(rendered).to include('ui = true')
      end
    end

    context 'with custom lease TTLs' do
      let(:properties) do
        { 'openbao' => { 'default_lease_ttl' => '24h', 'max_lease_ttl' => '24h' } }
      end
      let(:rendered) { template.render(properties, spec: spec_node1, consumes: links_3_node) }

      it 'sets custom default lease TTL' do
        expect(rendered).to include('default_lease_ttl = "24h"')
      end

      it 'sets custom max lease TTL' do
        expect(rendered).to include('max_lease_ttl     = "24h"')
      end
    end

    context 'standalone (1 node)' do
      let(:rendered) { template.render(properties, spec: spec_standalone, consumes: links_1_node) }

      it 'generates zero retry_join blocks' do
        expect(rendered).not_to include('retry_join')
      end
    end

    context 'with self-signed peer certs' do
      let(:properties) do
        { 'openbao' => { 'peer' => { 'tls' => { 'use_self_signed_certs' => true } } } }
      end
      let(:rendered) { template.render(properties, spec: spec_node1, consumes: links_3_node) }

      it 'omits leader_client_cert_file from retry_join' do
        expect(rendered).not_to include('leader_client_cert_file')
      end

      it 'omits leader_client_key_file from retry_join' do
        expect(rendered).not_to include('leader_client_key_file')
      end

      it 'still includes leader_ca_cert_file' do
        expect(rendered).to include('leader_ca_cert_file')
      end
    end

    context 'with operator peer certs (default)' do
      let(:rendered) { template.render(properties, spec: spec_node1, consumes: links_3_node) }

      it 'includes leader_client_cert_file' do
        expect(rendered).to include('leader_client_cert_file = "/var/vcap/jobs/openbao/tls/peer/cert.pem"')
      end

      it 'includes leader_client_key_file' do
        expect(rendered).to include('leader_client_key_file  = "/var/vcap/jobs/openbao/tls/peer/key.pem"')
      end
    end

    context 'retry_join TLS servername' do
      let(:rendered) { template.render(properties, spec: spec_node1, consumes: links_3_node) }

      it 'matches the vault serving-cert SAN, not the peer-cert SAN' do
        # leader_api_addr dials the API port (openbao.port), which presents
        # the vault serving cert (tls/vault/cert.pem, SAN "openbao.bosh"),
        # not the raft peer cert. leader_tls_servername must match what's
        # actually presented there or the retry_join TLS handshake fails.
        expect(rendered).to include('leader_tls_servername   = "openbao.bosh"')
      end
    end

    context 'cluster_addr' do
      let(:rendered) { template.render(properties, spec: spec_node1, consumes: links_3_node) }

      it 'uses port 8201 for cluster communication' do
        expect(rendered).to match(/cluster_addr\s+=\s+"https:\/\/.*:8201"/)
      end

      it 'binds the cluster listener on the advertised port 8201' do
        expect(rendered).to match(/cluster_address\s*=\s*"0\.0\.0\.0:8201"/)
      end
    end

    context 'self-exclusion with DNS-style peer addresses' do
      # Real deployments resolve link instance addresses to BOSH-DNS names,
      # not raw IPs (see dns/aliases.json.erb, which aliases spec.address).
      # This mirrors that: the link and spec addresses are DNS names while
      # spec.ip is a distinct, non-matching raw IP.
      let(:dns_links) do
        instances = [
          Bosh::Template::Test::LinkInstance.new(
            address: 'q1r2s3-abcd.openbao.default.my-deployment.bosh'
          ),
          Bosh::Template::Test::LinkInstance.new(
            address: 'q4r5s6-efgh.openbao.default.my-deployment.bosh'
          ),
          Bosh::Template::Test::LinkInstance.new(
            address: 'q7r8s9-ijkl.openbao.default.my-deployment.bosh'
          )
        ]
        [Bosh::Template::Test::Link.new(name: 'openbao', instances: instances)]
      end

      let(:spec_dns_self) do
        Bosh::Template::Test::InstanceSpec.new(
          ip: '10.0.0.1',
          address: 'q1r2s3-abcd.openbao.default.my-deployment.bosh'
        )
      end

      let(:rendered) { template.render(properties, spec: spec_dns_self, consumes: dns_links) }

      it 'excludes the local node from retry_join' do
        expect(rendered).not_to include('q1r2s3-abcd.openbao.default.my-deployment.bosh')
      end

      it 'generates retry_join blocks for the two remaining peers' do
        expect(rendered.scan('retry_join {').length).to eq(2)
      end
    end
  end

  # ── config/bpm.yml ──

  context 'config/bpm.yml' do
    let(:template) { job.template('config/bpm.yml') }

    context 'with defaults' do
      let(:rendered) { template.render(properties) }

      it 'sets default log level to info' do
        expect(rendered).to include('BAO_LOG_LEVEL: info')
      end

      it 'uses correct executable path' do
        expect(rendered).to include('/var/vcap/packages/openbao/bin/bao')
      end

      it 'includes IPC_LOCK capability' do
        expect(rendered).to include('IPC_LOCK')
      end

      it 'includes NET_BIND_SERVICE capability' do
        expect(rendered).to include('NET_BIND_SERVICE')
      end

      it 'references pre-start hook' do
        expect(rendered).to include('/var/vcap/jobs/openbao/bin/pre-start')
      end

      it 'passes server mode and config path' do
        parsed = YAML.safe_load(rendered)
        process = parsed['processes'].first
        expect(process['args']).to eq(['server', '-config=/var/vcap/jobs/openbao/config/openbao.hcl'])
      end

      it 'produces valid YAML' do
        expect { YAML.safe_load(rendered) }.not_to raise_error
      end
    end

    context 'with custom log level' do
      let(:properties) { { 'openbao' => { 'log_level' => 'debug' } } }
      let(:rendered) { template.render(properties) }

      it 'sets custom log level' do
        expect(rendered).to include('BAO_LOG_LEVEL: debug')
      end
    end
  end

  # ── TLS templates ──

  context 'TLS templates' do
    context 'tls/vault/cert.pem' do
      let(:template) { job.template('tls/vault/cert.pem') }

      it 'renders empty when no cert provided' do
        rendered = template.render(properties)
        expect(rendered.strip).to eq('')
      end

      it 'renders provided certificate' do
        props = { 'openbao' => { 'tls' => { 'certificate' => 'VAULT-CERT-DATA' } } }
        rendered = template.render(props)
        expect(rendered).to include('VAULT-CERT-DATA')
      end
    end

    context 'tls/vault/key.pem' do
      let(:template) { job.template('tls/vault/key.pem') }

      it 'renders empty when no key provided' do
        rendered = template.render(properties)
        expect(rendered.strip).to eq('')
      end

      it 'renders provided key' do
        props = { 'openbao' => { 'tls' => { 'key' => 'VAULT-KEY-DATA' } } }
        rendered = template.render(props)
        expect(rendered).to include('VAULT-KEY-DATA')
      end
    end

    context 'tls/peer/ca.pem' do
      let(:template) { job.template('tls/peer/ca.pem') }

      it 'renders empty when no CA provided' do
        rendered = template.render(properties)
        expect(rendered.strip).to eq('')
      end

      it 'renders provided CA certificate' do
        props = { 'openbao' => { 'peer' => { 'tls' => { 'ca' => 'PEER-CA-DATA' } } } }
        rendered = template.render(props)
        expect(rendered).to include('PEER-CA-DATA')
      end
    end

    context 'tls/peer/cert.pem' do
      let(:template) { job.template('tls/peer/cert.pem') }

      it 'renders empty when no cert provided' do
        rendered = template.render(properties)
        expect(rendered.strip).to eq('')
      end

      it 'renders provided peer certificate' do
        props = { 'openbao' => { 'peer' => { 'tls' => { 'certificate' => 'PEER-CERT-DATA' } } } }
        rendered = template.render(props)
        expect(rendered).to include('PEER-CERT-DATA')
      end
    end

    context 'tls/peer/key.pem' do
      let(:template) { job.template('tls/peer/key.pem') }

      it 'renders empty when no key provided' do
        rendered = template.render(properties)
        expect(rendered.strip).to eq('')
      end

      it 'renders provided peer key' do
        props = { 'openbao' => { 'peer' => { 'tls' => { 'key' => 'PEER-KEY-DATA' } } } }
        rendered = template.render(props)
        expect(rendered).to include('PEER-KEY-DATA')
      end
    end
  end

  # ── dns/aliases.json.erb ──

  context 'dns/aliases.json.erb' do
    let(:template) { job.template('dns/aliases.json') }

    context 'rendered output' do
      let(:rendered) { template.render(properties) }

      it 'produces valid JSON' do
        expect { JSON.parse(rendered) }.not_to raise_error
      end

      it 'uses openbao.internal domain' do
        parsed = JSON.parse(rendered)
        expect(parsed.keys.first).to match(/\.openbao\.internal$/)
      end

      it 'maps to an address array' do
        parsed = JSON.parse(rendered)
        value = parsed.values.first
        expect(value).to be_an(Array)
        expect(value.length).to eq(1)
      end
    end
  end
end
