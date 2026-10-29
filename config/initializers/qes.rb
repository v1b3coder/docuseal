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

# Trust store při startu: prázdný signing store znamená, že každý podpis skončí
# `not_trusted`, a z chyby to nepoznáte. Fail-fast by vypnul celou instanci,
# proto jen hlasitý log (issue #8).
Rails.application.config.after_initialize do
  next unless Qes::Config[:enabled]

  { trust_roots: 'signing', verification_trust_roots: 'verification',
    tsa_trust_roots: 'TSA' }.each do |key, label|
    roots = Qes.public_send(key)
    Rails.logger.info("[qes] #{label} trust store: #{roots.size} cert(s) from #{Qes::Config[key].inspect}")
  end

  if Qes.trust_roots.empty?
    Rails.logger.error('[qes] signing trust store is empty: every QES signature will fail with not_trusted')
  end
rescue StandardError => e
  Rails.logger.warn("[qes] could not report trust stores: #{e.class}: #{e.message}")
end

# Rozšíření upstream tříd (validace, callbacky, hooky) bez zásahu do jejich souborů.
Rails.application.config.to_prepare do
  Qes::Extensions.install!
end
