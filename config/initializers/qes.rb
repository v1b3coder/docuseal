# frozen_string_literal: true

# Konfigurace QES (SPEC § 11) + redakce citlivých parametrů v logu (SPEC § 7.9).
Rails.application.config.filter_parameters += %i[token signature data_to_sign certificate pin qpin]

Rails.application.config.after_initialize do
  # Defaulty jsou v `Qes::Config`; ENV je jen override (SPEC § 11).
  enabled = Qes::Config[:enabled]
  interval = Qes::Config[:expiry_job_interval].to_i

  Qes::ExpireSessionsJob.perform_in(0) if enabled && !Rails.env.test? && interval.positive?
rescue StandardError => e
  Rails.logger.warn("[qes] could not schedule expire job: #{e.class}")
end

# Rozšíření upstream tříd (validace, callbacky, hooky) bez zásahu do jejich souborů.
Rails.application.config.to_prepare do
  Qes::Extensions.install!
end
