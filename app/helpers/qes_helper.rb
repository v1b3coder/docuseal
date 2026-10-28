# frozen_string_literal: true

module QesHelper
  # Jeden dotaz na celou submission; non-QES šablony se nedotazují.
  def qes_sessions_by_submitter(submission)
    return {} unless Qes.enabled?
    return {} unless Qes.template_fields(submission).any? { |field| field['type'] == 'qes' }

    QesSession.completed.where(submission_id: submission.id).order(:id).to_a.group_by(&:submitter_id)
  end

  def qes_submitter_badge(submitter, sessions_by_submitter)
    session = submitter && sessions_by_submitter[submitter.id]&.last
    return unless session

    render 'submissions/qes_badge', session:
  end

  def qes_field_summary(field, submitter, compact: false)
    return unless field['type'] == 'qes'

    session = QesSession.completed_for(submitter, field['uuid'])
    return unless session

    render 'submit_form/qes_summary', session:, compact:
  end

  def qes_field_value(field, submitter, _local_assigns)
    qes_field_summary(field, submitter, compact: true)
  end

  def qes_verification_panel(template)
    report = template.preferences&.dig(Qes::VerifiedDocuments::REPORT_KEY)
    return if report.blank?

    render 'templates/qes_verification', template:, report:
  end
end
