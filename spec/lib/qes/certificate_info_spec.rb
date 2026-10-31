# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Qes::CertificateInfo do
  describe '.parse' do
    it 'maps QcCompliance to ades' do
      info = described_class.parse(QesHelpers.pki_path('signer-ades.crt').binread)

      expect(info.level).to eq('ades')
      expect(info.qc_statements).to eq(['QcCompliance'])
      expect(info.digital_signature?).to be true
    end

    it 'maps QcCompliance + QcSSCD to qes' do
      info = described_class.parse(QesHelpers.pki_path('signer-qscd.crt').binread)

      expect(info.level).to eq('qes')
      expect(info.qc_statements).to contain_exactly('QcCompliance', 'QcSSCD')
    end

    it 'returns none for a certificate without QCStatements' do
      info = described_class.parse(File.binread(QesHelpers::TEST_DIR.join('certs', 'signer.cert.pem')))

      expect(info.level).to eq('none')
    end

    it 'rejects an expired certificate' do
      info = described_class.parse(QesHelpers.pki_path('signer-expired.crt').binread)

      expect { info.validate!(level_required: 'ades', key_location: 'phone_keystore') }
        .to raise_error(Qes::ClientError) { |e| expect(e.code).to eq(:certificate_expired) }
    end

    it 'rejects a QcSSCD certificate used from the phone keystore' do
      info = described_class.parse(QesHelpers.pki_path('signer-qscd.crt').binread)

      expect { info.validate!(level_required: 'ades', key_location: 'phone_keystore') }
        .to raise_error(Qes::ClientError) { |e| expect(e.code).to eq(:level_mismatch) }
    end

    it 'requires QcSSCD for a qes field' do
      info = described_class.parse(QesHelpers.pki_path('signer-ades.crt').binread)

      expect { info.validate!(level_required: 'qes', key_location: 'phone_keystore') }
        .to raise_error(Qes::ClientError) { |e| expect(e.code).to eq(:qes_required_qscd) }
    end

    it 'accepts an ades certificate from the phone keystore' do
      info = described_class.parse(QesHelpers.pki_path('signer-ades.crt').binread)

      expect(info.validate!(level_required: 'ades', key_location: 'phone_keystore'))
        .to include(level: 'ades', key_type: 'rsa')
    end
  end

  describe 'certificate e-mail' do
    def certificate_with_san(*names, subject: '/C=CZ/O=Test/CN=Jan Novak')
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = OpenSSL::BN.rand(64)
      cert.subject = OpenSSL::X509::Name.parse(subject)
      cert.issuer = cert.subject
      cert.public_key = key.public_key
      cert.not_before = Time.current - 60
      cert.not_after = 1.day.from_now

      factory = OpenSSL::X509::ExtensionFactory.new
      factory.subject_certificate = cert
      factory.issuer_certificate = cert
      cert.add_extension(factory.create_extension('keyUsage', 'digitalSignature', true))
      cert.add_extension(factory.create_extension('subjectAltName', names.join(','), false)) if names.any?
      cert.sign(key, OpenSSL::Digest.new('SHA256'))

      described_class.parse(cert.to_der)
    end

    it 'returns the first SAN e-mail when the certificate has several' do
      info = certificate_with_san('email:jan@firma.cz', 'email:druhy@firma.cz')

      expect(info.email).to eq('jan@firma.cz')
      expect(info.email_addresses).to eq(['jan@firma.cz', 'druhy@firma.cz'])
    end

    it 'skips SAN entries that are not e-mail addresses' do
      info = certificate_with_san('DNS:example.com', 'email:jan@firma.cz')

      expect(info.email).to eq('jan@firma.cz')
    end

    it 'returns nil when the certificate has no SAN e-mail' do
      expect(certificate_with_san('DNS:example.com').email).to be_nil
    end

    it 'returns nil when the certificate has no subjectAltName' do
      expect(certificate_with_san.email).to be_nil
    end

    it 'builds the stamp identity from CN and the first e-mail' do
      info = certificate_with_san('email:jan@firma.cz', 'email:druhy@firma.cz')

      expect(info.stamp_identity).to eq('name' => 'Jan Novak', 'email' => 'jan@firma.cz')
    end

    it 'falls back to the full subject when the certificate has no CN' do
      info = certificate_with_san('email:jan@firma.cz', subject: '/C=CZ/O=Test')

      expect(info.stamp_identity).to eq('name' => '/C=CZ/O=Test', 'email' => 'jan@firma.cz')
    end
  end

  describe 'document signing key usage' do
    %w[digitalSignature nonRepudiation digitalSignature,nonRepudiation].each do |usage|
      it "accepts #{usage}" do
        key, certificate = QesHelpers.self_signed_qc_sscd_certificate
        factory = OpenSSL::X509::ExtensionFactory.new
        certificate.extensions = certificate.extensions.reject { |extension| extension.oid == 'keyUsage' }
        certificate.add_extension(factory.create_extension('keyUsage', usage, true))
        certificate.sign(key, OpenSSL::Digest.new('SHA256'))
        info = described_class.parse(certificate.to_der)

        expect(info.validate!(level_required: 'qes', key_location: 'card')).to include(level: 'qes')
      end
    end

    it 'rejects a certificate with neither signing bit' do
      key, certificate = QesHelpers.self_signed_qc_sscd_certificate
      factory = OpenSSL::X509::ExtensionFactory.new
      certificate.extensions = certificate.extensions.reject { |extension| extension.oid == 'keyUsage' }
      certificate.add_extension(factory.create_extension('keyUsage', 'keyEncipherment', true))
      certificate.sign(key, OpenSSL::Digest.new('SHA256'))
      info = described_class.parse(certificate.to_der)

      expect { info.validate!(level_required: 'qes', key_location: 'card') }
        .to raise_error(Qes::ClientError) { |error| expect(error.code).to eq(:invalid_certificate) }
    end
  end
end
