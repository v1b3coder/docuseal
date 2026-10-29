# frozen_string_literal: true

require 'rails_helper'

# N3: generátor výsledného PDF se vybírá podle dokončené QES session, ne podle
# šablony. Volitelné `qes` pole bez podpisu musí dostat upstream PDF (jinak
# nevznikne nic) a dokončená session musí zůstat finálním PDF i po změně šablony.
# `QES_ENABLED=false` zůstává feature gate: QES kód se pak nespustí.
RSpec.describe 'QES result attachments' do
  before do
    QesHelpers.configure!
    create(:encrypted_config, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))
  end

  def complete_session(submitter, pdf: '%PDF-1.7 qes-final')
    session = create(:qes_session, :with_values_snapshot, submitter:, account: submitter.account,
                                                           submission: submitter.submission,
                                                           state: 'completed', level: 'ades')
    session.final_document.attach(io: StringIO.new(pdf), filename: 'qes-final.pdf',
                                  content_type: 'application/pdf')
    session
  end

  it 'uses the upstream generator when an optional qes field has no completed session' do
    submission = QesHelpers.build_qes_submission
    submission.template_fields.each { |field| field['required'] = false if field['type'] == 'qes' }
    submission.save!
    submitter = submission.submitters.first
    submitter.update!(completed_at: Time.current)

    documents = Submissions::GenerateResultAttachments.call(submitter)

    expect(documents).to be_present
    expect(documents.first.download).to start_with('%PDF')
    expect(documents.first.metadata['sha256']).to be_present
  end

  it 'uses the QES final document when a session is completed' do
    submission = QesHelpers.build_qes_submission
    submitter = submission.submitters.first
    session = complete_session(submitter)
    submitter.update!(completed_at: Time.current)

    documents = Submissions::GenerateResultAttachments.call(submitter)

    expect(documents.map(&:download)).to eq([session.final_document.download])
  end

  it 'uses the QES final document after the qes field leaves the template snapshot' do
    submission = QesHelpers.build_qes_submission
    submitter = submission.submitters.first
    session = complete_session(submitter)
    submission.update!(template_fields: submission.template_fields.reject { |f| f['type'] == 'qes' })
    submitter.update!(completed_at: Time.current)

    documents = Submissions::GenerateResultAttachments.call(submitter)

    expect(documents.map(&:download)).to eq([session.final_document.download])
  end

  it 'uses the upstream generator when QES is disabled even with a completed session' do
    submission = QesHelpers.build_qes_submission
    submitter = submission.submitters.first
    complete_session(submitter)
    submitter.update!(completed_at: Time.current)
    Qes::Config[:enabled] = false

    documents = Submissions::GenerateResultAttachments.call(submitter)

    expect(documents).to be_present
    expect(documents.first.download).not_to eq(submitter.qes_sessions.completed.last.final_document.download)
  end

  it 'uses the QES final document for the merged document when a session is completed' do
    submission = QesHelpers.build_qes_submission
    submitter = submission.submitters.first
    session = complete_session(submitter)
    submitter.update!(completed_at: Time.current)

    attachment = Submissions::GenerateCombinedAttachment.call(submitter, with_audit: false)

    expect(attachment.name).to eq('merged_document')
    expect(attachment.download).to eq(session.final_document.download)
  end
end
