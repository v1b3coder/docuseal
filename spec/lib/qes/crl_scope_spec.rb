# frozen_string_literal: true

require 'rails_helper'

# N2: issuingDistributionPoint scope flags (RFC 5280):
# [1] onlyContainsUserCerts, [2] onlyContainsCACerts. Implicitly tagged
# BOOLEANs must be decoded, not treated as truthy strings.
RSpec.describe 'QES CRL scope' do
  def certificate(subject, issuer: nil, issuer_key: nil, key:, serial:, ca:)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = serial
    cert.subject = OpenSSL::X509::Name.parse(subject)
    cert.issuer = issuer ? issuer.subject : cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.current - 1.hour
    cert.not_after = Time.current + 1.day
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = cert
    factory.issuer_certificate = issuer || cert
    cert.add_extension(factory.create_extension('basicConstraints', ca ? 'CA:TRUE' : 'CA:FALSE', true))
    cert.sign(issuer_key || key, OpenSSL::Digest.new('SHA256'))
    cert
  end

  def crl(issuer, issuer_key, idp_der)
    result = OpenSSL::X509::CRL.new
    result.version = 1
    result.issuer = issuer.subject
    result.last_update = Time.current - 60
    result.next_update = Time.current + 1.hour
    result.add_extension(OpenSSL::X509::Extension.new('2.5.29.28', idp_der, 'critical'))
    result.sign(issuer_key, OpenSSL::Digest.new('SHA256'))
    result
  end

  def idp(tag, value)
    OpenSSL::ASN1::Sequence(
      [OpenSSL::ASN1::ASN1Data.new(value.b, tag, :CONTEXT_SPECIFIC)]
    ).to_der
  end

  let(:root_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:root) { certificate('/CN=Scope Root', key: root_key, serial: 1, ca: true) }
  let(:leaf_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:leaf) { certificate('/CN=Scope Leaf', issuer: root, issuer_key: root_key, key: leaf_key, serial: 2, ca: false) }

  it 'accepts onlyContainsUserCerts for an end-entity certificate' do
    expect { Qes::Ltv.validate_crl_scope!(crl(root, root_key, idp(1, "\xFF")), leaf) }
      .not_to raise_error
  end

  it 'rejects onlyContainsUserCerts for a CA certificate' do
    expect { Qes::Ltv.validate_crl_scope!(crl(root, root_key, idp(1, "\xFF")), root) }
      .to raise_error(Qes::Ltv::FetchError, /user certificates/)
  end

  it 'rejects onlyContainsCACerts for an end-entity certificate' do
    expect { Qes::Ltv.validate_crl_scope!(crl(root, root_key, idp(2, "\xFF")), leaf) }
      .to raise_error(Qes::Ltv::FetchError, /CA certificates/)
  end

  it 'accepts onlyContainsCACerts for a CA certificate' do
    expect { Qes::Ltv.validate_crl_scope!(crl(root, root_key, idp(2, "\xFF")), root) }
      .not_to raise_error
  end

  it 'does not treat an explicit FALSE as TRUE' do
    expect { Qes::Ltv.validate_crl_scope!(crl(root, root_key, idp(1, "\x00")), leaf) }
      .not_to raise_error
  end
end
