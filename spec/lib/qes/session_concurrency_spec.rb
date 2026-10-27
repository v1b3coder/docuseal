# frozen_string_literal: true

require 'rails_helper'

# S3: přechody musí být atomické a na submission smí být jen jedna
# připravená podpisová revize.
RSpec.describe 'QES session concurrency', type: :request do
  before { QesHelpers.configure! }

  def session_for(submitter, field_uuid)
    create(:qes_session, :with_values_snapshot, submitter:, submission: submitter.submission,
                                                account: submitter.account, field_uuid:, state: 'awaiting_signature')
  end

  it 'does not let a stale in-memory transition overwrite completed' do
    submitter = QesHelpers.build_qes_submitter
    field = submitter.submission.template_fields.find { |item| item['type'] == 'qes' }
    session = session_for(submitter, field['uuid'])
    stale = QesSession.find(session.id)
    fresh = QesSession.find(session.id)
    %w[signed embedded validated completed].each { |state| Qes::SessionManager.transition!(fresh, state) }

    expect do
      Qes::SessionManager.transition!(stale, 'cancelled')
    end.to raise_error(Qes::InvalidTransition)

    expect(session.reload.state).to eq('completed')
  end

  it 'rejects a second QES field while the first is awaiting signature' do
    submitter = QesHelpers.build_qes_submission(qes_fields_per_submitter: 2).submitters.first
    fields = submitter.submission.template_fields.select { |item| item['type'] == 'qes' }
    first, second = fields.first(2)
    session = session_for(submitter, first['uuid'])
    sign_in(submitter.submission.template.author)

    expect do
      post "/s/#{submitter.slug}/qes_sessions", params: { field_uuid: second['uuid'] }
    end.not_to change(QesSession, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['error']).to eq('signature_in_progress')
    expect(session.reload.state).to eq('awaiting_signature')
  end

  it 'refuses completion when the signature base changed after preparation' do
    submitter = QesHelpers.build_qes_submitter
    field = submitter.submission.template_fields.find { |item| item['type'] == 'qes' }
    session = session_for(submitter, field['uuid'])
    session.tbs_document.attach(ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('%PDF-1.7'), filename: 'tbs.pdf', content_type: 'application/pdf',
      metadata: { qes_values: {}, qes_document_manifest: [], qes_base_digest: 'old' }
    ))
    allow(Qes::TbsDocument).to receive(:base_digest).and_return('new')

    expect do
      Qes::Providers::MobileApp.new(session).complete!('signature')
    end.to raise_error(Qes::ClientError) { |error| expect(error.code).to eq(:document_set_changed) }
  end
end
