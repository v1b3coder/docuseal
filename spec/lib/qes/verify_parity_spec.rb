# frozen_string_literal: true

require 'rails_helper'

# Regrese R1/R2 z docs/22-final-audit-fork.md: sdílené ověření PDF musí
# u nedůvěryhodného podpisu dál hlásit přidaná data a CAdES musí být
# trusted přes certy účtu (ne jen přes QES trust roots).
RSpec.describe 'PDF verification parity' do
  before { QesHelpers.configure! }

  def cades_pdf(pkcs: QesHelpers.pkcs12)
    QesHelpers.signed_pdf(pkcs:)
  end

  it 'reports unsigned changes after an untrusted signature' do
    allow(Qes).to receive(:trust_roots).and_return([])
    pdf = "#{cades_pdf}\n% injected\n"

    signature = Qes::PdfiumTrust.report(StringIO.new(pdf), []).first

    expect(signature).to have_attributes(verified: true, trusted: false, modified: true)
    expect(signature.messages.map(&:text))
      .to include(I18n.t('contains_unsigned_changes_after_the_last_signature'))
  end

  it 'reports unsigned changes with empty trusted ranges (QES validator)' do
    pdf = "#{cades_pdf}\n% injected\n"

    signature = Qes::PdfiumTrust.report(StringIO.new(pdf), [], trusted_ranges: []).first

    expect(signature).to have_attributes(verified: true, modified: true)
  end

  it 'does not report changes for an intact untrusted signature' do
    allow(Qes).to receive(:trust_roots).and_return([])
    signature = Qes::PdfiumTrust.report(StringIO.new(cades_pdf), []).first

    expect(signature).to have_attributes(verified: true, trusted: false, modified: false)
  end

  it 'trusts a CAdES signature via account trusted certificates' do
    pkcs = QesHelpers.pkcs12
    allow(Qes).to receive(:trust_roots).and_return([])

    signature = Qes::PdfiumTrust.report(StringIO.new(cades_pdf(pkcs:)), [pkcs.certificate]).first

    expect(signature).to have_attributes(verified: true, trusted: true)
    expect(signature.messages.map(&:text)).to include(I18n.t('signed_with_trusted_certificate'))
  end

  it 'does not trust a CAdES signature made by a CA certificate' do
    pkcs = QesHelpers.self_signed_ca_pkcs12
    allow(Qes).to receive(:trust_roots).and_return([])

    signature = Qes::PdfiumTrust.report(StringIO.new(cades_pdf(pkcs:)), [pkcs.certificate]).first

    expect(signature).to have_attributes(verified: true, trusted: false)
    expect(signature.messages.map(&:text)).not_to include(I18n.t('signed_with_trusted_certificate'))
  end

  it 'keeps DocuSeal adbe.pkcs7.detached signatures trusted via account certificates' do
    pkcs = QesHelpers.pkcs12
    pdf = Qes::TbsDocument.merged_document(QesHelpers.build_qes_submitter)
    io = StringIO.new

    pdf.sign(io, certificate: pkcs.certificate, key: pkcs.key, certificate_chain: pkcs.ca_certs,
                 signature_type: :adbe_pkcs7_detached)

    signature = Qes::PdfiumTrust.report(StringIO.new(io.string), [pkcs.certificate]).first

    expect(signature).to have_attributes(verified: true, trusted: true, modified: false)
  end
end
