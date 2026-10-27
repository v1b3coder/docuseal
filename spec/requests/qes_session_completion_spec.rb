# frozen_string_literal: true

require 'rails_helper'

# S1: dokončení submissionu musí být vázané na session token, ne na
# submitter z deep linku a plný API token účtu.
RSpec.describe 'QES session completion', type: :request do
  before { QesHelpers.configure! }

  it 'completes only the submitter bound to the session token' do
    submission = QesHelpers.build_qes_submission(count: 2)
    first, second = submission.submitters.order(:id).to_a
    field = Qes.template_fields(submission).find { |item| item['type'] == 'qes' }
    session = create(:qes_session, :with_values_snapshot, submitter: first, submission:,
                                                          account: submission.account,
                                                          field_uuid: field['uuid'],
                                                          state: 'completed',
                                                          completed_at: Time.current,
                                                          level: 'ades')
    session.update!(token_digest: Qes::Token.digest('session-complete'))
    first.update!(values: first.values.merge(field['uuid'] => "qes:#{session.id}"))

    post '/qes/sessions/session-complete/complete_submission'

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['submitter_id']).to eq(first.id)
    expect(first.reload.completed_at).to be_present
    expect(second.reload.completed_at).to be_nil
  end
end
