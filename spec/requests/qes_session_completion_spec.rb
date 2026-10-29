# frozen_string_literal: true

require 'rails_helper'

# S1: dokončení submissionu musí být vázané na session token, ne na
# submitter z deep linku a plný API token účtu.
# #14: dokončení navíc nesmí projít nad archivovanou ani expirovanou submissioní.
RSpec.describe 'QES session completion', type: :request do
  before { QesHelpers.configure! }

  # Session ve stavu `completed` (podpis už je v PDF) s tokenem v cestě.
  def completed_session(token)
    submission = QesHelpers.build_qes_submission(count: 2)
    submitter = submission.submitters.order(:id).first
    field = Qes.template_fields(submission).find { |item| item['type'] == 'qes' }

    session = create(:qes_session, :with_values_snapshot, submitter:, submission:,
                                                        account: submission.account,
                                                        field_uuid: field['uuid'],
                                                        state: 'completed',
                                                        completed_at: Time.current,
                                                        level: 'ades')
    session.update!(token_digest: Qes::Token.digest(token))
    submitter.update!(values: submitter.values.merge(field['uuid'] => "qes:#{session.id}"))

    [session, submitter]
  end

  it 'completes only the submitter bound to the session token' do
    session, first = completed_session('session-complete')
    second = session.submission.submitters.order(:id).last

    post '/qes/sessions/session-complete/complete_submission'

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['submitter_id']).to eq(first.id)
    expect(first.reload.completed_at).to be_present
    expect(second.reload.completed_at).to be_nil
  end

  it 'rejects completion when the submission was archived after signing' do
    session, submitter = completed_session('session-archived')
    session.submission.update!(archived_at: Time.current)

    post '/qes/sessions/session-archived/complete_submission'

    expect(response).to have_http_status(:gone)
    expect(response.parsed_body['error']).to eq('form_not_active')
    expect(submitter.reload.completed_at).to be_nil
  end

  it 'rejects completion when the submission has expired' do
    session, submitter = completed_session('session-expired')
    session.submission.update!(expire_at: 1.minute.ago)

    post '/qes/sessions/session-expired/complete_submission'

    expect(response).to have_http_status(:gone)
    expect(response.parsed_body['error']).to eq('form_not_active')
    expect(submitter.reload.completed_at).to be_nil
  end
end
