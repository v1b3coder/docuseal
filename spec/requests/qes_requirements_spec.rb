# frozen_string_literal: true

require 'rails_helper'

# N1: povinný QES požadavek musí být zmrazený při vzniku submissionu.
# Guard nesmí číst aktuální šablonu (později přidané pole blokuje staré
# submissiony) ani mutable submission.template_fields (API required: false).
RSpec.describe 'QES completion requirements', type: :request do
  before { QesHelpers.configure! }

  def auth_headers(template)
    { 'X-Auth-Token' => template.author.access_token.token }
  end

  it 'rejects completion of a merged-role submission created without a QES session' do
    template = QesHelpers.build_qes_submission(count: 2).template
    roles = template.submitters.map { |submitter| submitter['name'] }

    post "/api/templates/#{template.id}/submissions", headers: auth_headers(template), as: :json, params: {
      send_email: false,
      submitters: [{ email: 'merged@example.test', roles:, completed: false }]
    }
    expect(response).to have_http_status(:ok)

    merged = Submission.order(:id).last.submitters.first
    expect(merged.qes_sessions).to be_empty

    put "/api/submitters/#{merged.id}", headers: auth_headers(template), as: :json,
                                            params: { completed: true }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('Required QES signatures are missing')
    expect(merged.reload.completed_at).to be_nil
  end

  it 'completes a submission created before the template gained a QES field' do
    account = FactoryBot.create(:account)
    user = FactoryBot.create(:user, account:)
    template = FactoryBot.create(:template, account:, author: user, only_field_types: %w[text],
                                 submitter_count: 1, attachment_count: 1)
    submission = FactoryBot.create(:submission, template:, account:)
    submitter_uuid = template.submitters.first['uuid']
    values = template.fields.each_with_object({}) do |field, result|
      result[field['uuid']] = 'Test signer' if field['type'] == 'text' && field['required']
    end
    submitter = FactoryBot.create(:submitter, submission:, account_id: account.id,
                                 uuid: submitter_uuid, values:)

    template.update!(fields: template.fields + [{
      'uuid' => SecureRandom.uuid,
      'submitter_uuid' => submitter_uuid,
      'name' => 'QES signature',
      'type' => 'qes',
      'required' => true,
      'preferences' => { 'level' => 'ades' },
      'areas' => []
    }])

    put "/api/submitters/#{submitter.id}", headers: auth_headers(template), as: :json,
                                        params: { completed: true }

    expect(response).to have_http_status(:ok)
    expect(submitter.reload.completed_at).to be_present
  end

  it 'keeps a required QES field required when the API sets required: false' do
    template = QesHelpers.build_qes_submission.template
    submitter = Submission.order(:id).last.submitters.first
    field = Qes.template_fields(Submission.order(:id).last).find { |item| item['type'] == 'qes' }

    put "/api/submitters/#{submitter.id}", headers: auth_headers(template), as: :json,
                                        params: { fields: [{ uuid: field['uuid'], required: false }] }

    expect(response).to have_http_status(:ok)

    put "/api/submitters/#{submitter.id}", headers: auth_headers(template), as: :json,
                                        params: { completed: true }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('Required QES signatures are missing')
  end

  # #2: volitelné QES pole nesmí vypnout kontrolu povinných polí (regrese d845ba42).
  it 'rejects completion with a missing required value when the QES field is optional' do
    submission = QesHelpers.build_qes_submission
    submitter = submission.submitters.first
    text = submission.template_fields.find { |field| field['type'] == 'text' && field['required'] }
    fields = submission.template_fields.map do |field|
      field['type'] == 'qes' ? field.merge('required' => false) : field
    end
    submission.update!(template_fields: fields)
    submitter.update!(values: {})

    put submit_form_path(slug: submitter.slug), params: { completed: 'true' }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['field_uuid']).to eq(text['uuid'])
    expect(submitter.reload.completed_at).to be_nil
  end

  # #16: úroveň a povinnost QES pole jsou zmrazené ve snapshotu submissionu;
  # API je nesmí změnit a čtou se ze submissionu, ne z šablony.
  it 'ignores a QES level change on an in-flight submission' do
    submission = QesHelpers.build_qes_submission(level: 'qes')
    submitter = submission.submitters.first
    field = submission.template_fields.find { |item| item['type'] == 'qes' }

    put "/api/submitters/#{submitter.id}", headers: auth_headers(submission.template), as: :json,
                                           params: { fields: [{ uuid: field['uuid'], preferences: { level: 'ades' } }] }

    expect(response).to have_http_status(:ok)

    frozen = Qes.template_fields(submission.reload).find { |item| item['type'] == 'qes' }
    expect(frozen.dig('preferences', 'level')).to eq('qes')

    create(:qes_session, :with_values_snapshot, submitter:, submission:, account: submitter.account,
                                                field_uuid: field['uuid'], state: 'completed', level: 'ades')

    put "/api/submitters/#{submitter.id}", headers: auth_headers(submission.template), as: :json,
                                           params: { completed: true }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('Required QES signatures are missing')
  end

  it 'freezes QES field requirements when the API creates a submission' do
    template = QesHelpers.build_qes_submission(level: 'qes').template

    post "/api/templates/#{template.id}/submissions", headers: auth_headers(template), as: :json, params: {
      send_email: false,
      submitters: [{ email: 'signer@example.test', role: template.submitters.first['name'] }]
    }

    expect(response).to have_http_status(:ok)

    submission = Submission.order(:id).last
    frozen = submission.template_fields.find { |item| item['type'] == 'qes' }

    expect(frozen).to be_present
    expect(frozen['required']).to be(true)
    expect(frozen.dig('preferences', 'level')).to eq('qes')
  end

  it 'ignores a QES level passed with the API submission' do
    template = QesHelpers.build_qes_submission(level: 'qes').template
    field = template.fields.find { |item| item['type'] == 'qes' }

    post "/api/templates/#{template.id}/submissions", headers: auth_headers(template), as: :json, params: {
      send_email: false,
      submitters: [{ email: 'signer@example.test', role: template.submitters.first['name'],
                     fields: [{ uuid: field['uuid'], preferences: { level: 'ades' } }] }]
    }

    expect(response).to have_http_status(:ok)

    frozen = Qes.template_fields(Submission.order(:id).last).find { |item| item['type'] == 'qes' }
    expect(frozen.dig('preferences', 'level')).to eq('qes')
  end

  it 'keeps the QES level of an in-flight submission when the template changes' do
    template = QesHelpers.build_qes_submission(level: 'qes').template

    post "/api/templates/#{template.id}/submissions", headers: auth_headers(template), as: :json, params: {
      send_email: false,
      submitters: [{ email: 'signer@example.test', role: template.submitters.first['name'] }]
    }
    submission = Submission.order(:id).last

    template.update!(fields: template.fields.map do |field|
      next field unless field['type'] == 'qes'

      field.merge('preferences' => field['preferences'].merge('level' => 'ades'))
    end)

    frozen = Qes.template_fields(submission.reload).find { |item| item['type'] == 'qes' }
    expect(frozen.dig('preferences', 'level')).to eq('qes')
  end
end
