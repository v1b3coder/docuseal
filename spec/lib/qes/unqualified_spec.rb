# frozen_string_literal: true

require 'rails_helper'

# S5: CAdES podpis s certifikátem bez QcStatements je důvěryhodný, ale
# nekvalifikovaný; verdikt musí být valid_unqualified, ne valid.
RSpec.describe 'QES unqualified CAdES' do
  before { QesHelpers.configure! }

  def unqualified_pkcs12
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse('/C=CZ/O=Test/CN=Unqualified')
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.current - 1.hour
    cert.not_after = Time.current + 1.day
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = cert
    factory.issuer_certificate = cert
    cert.add_extension(factory.create_extension('keyUsage', 'digitalSignature', true))
    cert.sign(key, OpenSSL::Digest.new('SHA256'))

    OpenSSL::PKCS12.create('test', 'test', key, cert)
  end

  it 'returns valid_unqualified for a trusted CAdES without QcStatements' do
    pkcs = unqualified_pkcs12
    pdf = QesHelpers.signed_pdf(pkcs:)
    allow(Qes).to receive(:trust_roots).and_return([pkcs.certificate])

    report = Qes::Verifier.call(pdf, name: 'unqualified.pdf')

    expect(report[:signatures].first).to include(level: 'none', trusted: true)
    expect(report[:verdict]).to eq('valid_unqualified')
  end
end
