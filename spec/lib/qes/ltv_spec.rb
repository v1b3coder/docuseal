# frozen_string_literal: true

require 'rails_helper'

# LTV (SPEC § 7.4): CRL pro DSS slovník a URL z certifikátu se smí
# stahovat jen z allowlistu (SSRF ochrana).
RSpec.describe Qes::Ltv do
  before { QesHelpers.configure! }

  def issue_certificate(name, issuer: nil, issuer_key: nil, ca: false, cdp: nil)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.rand(64)
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{name}")
    cert.issuer = issuer ? issuer.subject : cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.current - 3600
    cert.not_after = Time.current + 3600
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = cert
    factory.issuer_certificate = issuer || cert
    cert.add_extension(factory.create_extension('basicConstraints', ca ? 'CA:TRUE' : 'CA:FALSE', true))
    cert.add_extension(factory.create_extension('crlDistributionPoints', "URI:#{cdp}")) if cdp
    cert.sign(issuer_key || key, OpenSSL::Digest.new('SHA256'))

    [key, cert]
  end

  def issue_crl(issuer, key, revoked: [], last_update: Time.current - 60, next_update: Time.current + 3600,
                extensions: [])
    crl = OpenSSL::X509::CRL.new
    crl.version = 1
    crl.issuer = issuer.subject
    crl.last_update = last_update
    crl.next_update = next_update
    revoked.each do |cert|
      entry = OpenSSL::X509::Revoked.new
      entry.serial = cert.serial
      entry.time = Time.current - 60
      crl.add_revoked(entry)
    end
    extensions.each { |extension| crl.add_extension(extension) }
    crl.sign(key, OpenSSL::Digest.new('SHA256'))

    crl
  end

  describe 'CRL freshness and chain scope' do
    let(:root_pair) { issue_certificate('Root', ca: true) }
    let(:root_key) { root_pair.first }
    let(:root) { root_pair.last }
    let(:intermediate_pair) { issue_certificate('Intermediate', issuer: root, issuer_key: root_key, ca: true) }
    let(:intermediate_key) { intermediate_pair.first }
    let(:intermediate) { intermediate_pair.last }
    let(:leaf_pair) { issue_certificate('Leaf', issuer: intermediate, issuer_key: intermediate_key) }
    let(:leaf) { leaf_pair.last }

    before { allow(Qes).to receive(:trust_roots).and_return([root]) }

    it 'requires advertised revocation data even for an explicitly trusted self-signed signer' do
      factory = OpenSSL::X509::ExtensionFactory.new
      root.add_extension(factory.create_extension('crlDistributionPoints', 'URI:https://crl.test/root'))
      root.sign(root_key, OpenSSL::Digest.new('SHA256'))
      allow(described_class).to receive(:fetch_first_crl).and_raise(Qes::Ltv::FetchError, 'unavailable')

      expect { described_class.fetch_crls(root) }
        .to raise_error(Qes::ClientError) { |error| expect(error.code).to eq(:ltv_unavailable) }
      expect { described_class.check_revoked!(root, crls: []) }
        .to raise_error(Qes::ClientError) { |error| expect(error.code).to eq(:ltv_unavailable) }
    end

    it 'rejects expired and future CRLs, allowing a small clock skew' do
      [
        issue_crl(root, root_key, next_update: Time.current - 600),
        issue_crl(root, root_key, last_update: Time.current + 600)
      ].each do |crl|
        expect { described_class.validate_crl!(crl, intermediate, root) }
          .to raise_error(Qes::Ltv::FetchError, /validity period/)
      end

      crl = issue_crl(root, root_key, next_update: Time.current - 60)
      expect { described_class.validate_crl!(crl, intermediate, root) }.not_to raise_error
    end

    it 'collects both CRLs with the root supplied only by server configuration' do
      leaf_crl = issue_crl(intermediate, intermediate_key)
      root_crl = issue_crl(root, root_key)
      allow(described_class).to receive(:crl_urls).with(leaf).and_return(['https://crl.test/leaf'])
      allow(described_class).to receive(:crl_urls).with(intermediate).and_return(['https://crl.test/intermediate'])
      allow(described_class).to receive(:fetch_first_crl).with(['https://crl.test/leaf']).and_return(leaf_crl)
      allow(described_class).to receive(:fetch_first_crl).with(['https://crl.test/intermediate']).and_return(root_crl)

      expect(described_class.collect_revocation_data(leaf, chain: [intermediate]))
        .to eq([leaf_crl, root_crl])
    end

    it 'rejects a non-root certificate without CRL DP when LTV is required' do
      Qes::Config[:require_ltv] = true
      leaf_with_cdp = issue_certificate('Leaf', issuer: intermediate, issuer_key: intermediate_key,
                                                cdp: 'https://crl.test/leaf').last
      leaf_crl = issue_crl(intermediate, intermediate_key)
      allow(described_class).to receive(:fetch_first_crl)
        .with(['https://crl.test/leaf']).and_return(leaf_crl)

      expect { described_class.fetch_crls(leaf_with_cdp, chain: [intermediate]) }
        .to raise_error(Qes::ClientError) { |error| expect(error.code).to eq(:ltv_unavailable) }
      expect { described_class.check_revoked!(leaf_with_cdp, chain: [intermediate], crls: [leaf_crl]) }
        .to raise_error(Qes::ClientError) { |error| expect(error.code).to eq(:ltv_unavailable) }
    end

    it 'accepts a non-root certificate without CRL DP when LTV is not required' do
      Qes::Config[:require_ltv] = false
      leaf_with_cdp = issue_certificate('Leaf', issuer: intermediate, issuer_key: intermediate_key,
                                                cdp: 'https://crl.test/leaf').last
      leaf_crl = issue_crl(intermediate, intermediate_key)
      allow(described_class).to receive(:fetch_first_crl)
        .with(['https://crl.test/leaf']).and_return(leaf_crl)

      expect(described_class.collect_revocation_data(leaf_with_cdp, chain: [intermediate])).to eq([leaf_crl])
      expect { described_class.check_revoked!(leaf_with_cdp, chain: [intermediate], crls: [leaf_crl]) }
        .not_to raise_error
    end

    it 'rejects delta CRLs instead of treating them as complete CRLs' do
      delta = issue_crl(intermediate, intermediate_key,
                        extensions: [OpenSSL::X509::Extension.new(
                          '2.5.29.27', OpenSSL::ASN1::Integer(1).to_der, true
                        )])

      expect { described_class.validate_crl!(delta, leaf, intermediate) }
        .to raise_error(Qes::Ltv::FetchError, /Delta CRLs/)
    end

    it 'rejects CRL numbers that decrease with a newer lastUpdate' do
      older = issue_crl(intermediate, intermediate_key, last_update: 2.minutes.ago,
                        extensions: [OpenSSL::X509::Extension.new(
                          '2.5.29.20', OpenSSL::ASN1::Integer(2).to_der, false
                        )])
      newer = issue_crl(intermediate, intermediate_key, last_update: 1.minute.ago,
                        extensions: [OpenSSL::X509::Extension.new(
                          '2.5.29.20', OpenSSL::ASN1::Integer(1).to_der, false
                        )])

      expect { described_class.check_revoked!(leaf, chain: [intermediate], crls: [older, newer]) }
        .to raise_error(Qes::ClientError) { |error| expect(error.code).to eq(:ltv_unavailable) }
    end

    it 'returns 422 for a malformed chain instead of raising a server error' do
      expect { described_class.check_revoked!(leaf, chain: ['not a certificate'],
                                             crls: [issue_crl(intermediate, intermediate_key)]) }
        .to raise_error(Qes::ClientError) { |error| expect(error.code).to eq(:invalid_certificate) }
    end

    it 'rejects a revoked intermediate even when the leaf is not revoked' do
      crls = [issue_crl(intermediate, intermediate_key), issue_crl(root, root_key, revoked: [intermediate])]

      expect { described_class.check_revoked!(leaf, chain: [intermediate.to_der], crls:) }
        .to raise_error(Qes::ClientError) { |error| expect(error.code).to eq(:revoked) }
    end

    it 'does not match a serial in a CRL from another issuer' do
      crl = issue_crl(root, root_key, revoked: [leaf])

      expect { described_class.check_revoked!(leaf, chain: [intermediate], crls: [crl]) }.not_to raise_error
    end

    it 'rejects fresh revocation at completion before building or embedding the CMS' do
      earlier = issue_crl(intermediate, intermediate_key)
      described_class.check_revoked!(leaf, chain: [intermediate], crls: [earlier])
      fresh = issue_crl(intermediate, intermediate_key, revoked: [leaf])
      allow(described_class).to receive(:fetch_crls).and_return([fresh])
      session = double('session', state: 'awaiting_signature', certificate: leaf,
                                  tbs_document: double(blob: double(metadata: { 'qes_values' => {} })),
                                  signed_attrs_der: 'signed attributes', hash_algorithm: 'SHA256',
                                  certificate_chain: [leaf, intermediate].map { |cert| Base64.strict_encode64(cert.to_der) })
      provider = Qes::Providers::MobileApp.new(session)
      signature = leaf_pair.first.sign(OpenSSL::Digest.new('SHA256'), session.signed_attrs_der)

      expect(provider).not_to receive(:build_cms)
      expect(provider).not_to receive(:embed)
      expect { provider.complete!(signature) }
        .to raise_error(Qes::ClientError) { |error| expect(error.code).to eq(:revoked) }
    end
  end

  describe '.private_address?' do
    %w[100.64.0.0 100.127.255.255 0.0.0.0 0.255.255.255 169.254.1.1
       10.0.0.1 172.16.0.1 192.168.1.1 127.0.0.1 :: ::1 fc00::1 fdff::1 fe80::1
       ::ffff:192.168.1.1 ::ffff:100.64.0.1 ::ffff:127.0.0.1 ::ffff:0.0.0.0
       ::ffff:169.254.1.1].each do |address|
      it "rejects #{address}" do
        expect(described_class.private_address?(address)).to be true
      end
    end

    %w[100.63.255.255 100.128.0.0 1.1.1.1 2606:4700:4700::1111 ::ffff:1.1.1.1].each do |address|
      it "allows the public address #{address}" do
        expect(described_class.private_address?(address)).to be false
      end
    end
  end

  describe '.validate_url!' do
    it 'allows an explicitly allowlisted host over http (testy)' do
      expect { described_class.validate_url!(URI.parse('http://127.0.0.1:8765/root.crl')) }
        .not_to raise_error
    end

    # I.CA CRL DP jsou jen http a https na qcrldp1.ica.cz neodpovídá, takže
    # prázdný allowlist (jen https + veřejná adresa) pro I.CA nestačí.
    it 'allows the I.CA CRL hosts from the default allowlist' do
      Qes::Config.reset!
      allow(described_class).to receive(:resolved_addresses).with('qcrldp1.ica.cz')
        .and_return(['93.185.100.10'])

      expect { described_class.validate_url!(URI.parse('http://qcrldp1.ica.cz/rca22_rsa.crl')) }
        .not_to raise_error
    end

    it 'covers every I.CA CRL distribution point host from the verification bundle' do
      allowed = Qes::Config::DEFAULTS[:ltv_allowed_hosts].split(',')
      certs = Rails.root.join('config/qes/czech.pem').read
                   .scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
                   .map { |pem| OpenSSL::X509::Certificate.new(pem) }
      hosts = certs.filter_map do |cert|
        # `subject.to_s` je ASCII-8BIT s escapovanými bajty, proto se hledá jen ASCII část CN.
        next unless cert.subject.to_s.include?('I.CA')

        described_class.crl_urls(cert).filter_map { |url| URI.parse(url).host }.first
      end

      expect(hosts).not_to be_empty
      expect(allowed).to include(*hosts)
    end

    it 'rejects a host outside the allowlist' do
      expect { described_class.validate_url!(URI.parse('http://127.0.0.1:8765/root.crl')) }
        .not_to raise_error
      expect { described_class.validate_url!(URI.parse('http://169.254.169.254/latest/meta-data/')) }
        .to raise_error(Qes::Ltv::FetchError, /not in QES_LTV_ALLOWED_HOSTS/)
    end

    it 'requires https for a public host when no allowlist is set' do
      Qes::Config[:ltv_allowed_hosts] = nil

      expect { described_class.validate_url!(URI.parse('http://example.com/root.crl')) }
        .to raise_error(Qes::Ltv::FetchError, /https/)
    end

    it 'rejects a private address when no allowlist is set' do
      Qes::Config[:ltv_allowed_hosts] = nil

      expect { described_class.validate_url!(URI.parse('http://127.0.0.1:8765/root.crl')) }
        .to raise_error(Qes::Ltv::FetchError)
      expect { described_class.validate_url!(URI.parse('https://127.0.0.1/root.crl')) }
        .to raise_error(Qes::Ltv::FetchError, /private address/)
      expect { described_class.validate_url!(URI.parse('https://169.254.169.254/latest/meta-data/')) }
        .to raise_error(Qes::Ltv::FetchError, /private address/)
    end

    it 'rejects unsupported schemes' do
      expect { described_class.validate_url!(URI.parse('file:///etc/passwd')) }
        .to raise_error(Qes::Ltv::FetchError, /scheme/)
    end
  end

  describe '.fetch_first_crl' do
    # Odmítnutý host se musí dostat ke klientovi, ne jen do logu serveru.
    it 'names the rejected host when no CRL can be fetched' do
      Qes::Config[:ltv_allowed_hosts] = 'crl.postsignum.cz'

      expect { described_class.fetch_first_crl(['http://127.0.0.1:8765/root.crl']) }
        .to raise_error(Qes::Ltv::FetchError, /127\.0\.0\.1.*QES_LTV_ALLOWED_HOSTS/)
    end
  end
end
