# frozen_string_literal: true

module Qes
  # Expirace neaktivních sessions (SPEC § 7.8). Fork nemá plánovač, proto se job
  # sám přeplánuje (`perform_in`); inicializér zařadí první běh při bootu.
  # Duplicitní smyčky po restartu vylučuje časové okno přes `LockEvent`.
  class ExpireSessionsJob
    include Sidekiq::Job

    LOCK_KEY = 'qes_expire_sessions'

    def perform
      # `QES_ENABLED=false` je feature gate (nález #10): naplánovaný job
      # nesmí dál měnit stav QES sessions.
      return unless Qes.enabled?

      QesSession.stale.find_each do |session|
        QesSession.stale.where(id: session.id).where.not(state: 'completed')
                  .update_all(state: 'expired', failure_code: 'expired',
                              expired_at: Time.current, updated_at: Time.current)
        session.reload
        Qes.log(session)
      rescue Qes::InvalidTransition
        nil
      end
    ensure
      # `ensure`: výjimka (např. timeout DB) nesmí zastavit smyčku expirace.
      reschedule!
    end

    def reschedule!
      interval = Qes::Config[:expiry_job_interval].to_i
      return unless Qes.enabled? && interval.positive?

      # Atomický lock v cache: při souběžném startu dvou procesů naplánuje
      # smyčku jen ten, kdo klíč vytvoří (Redis/MemoryStore unless_exist).
      return unless Rails.cache.write(LOCK_KEY, true, unless_exist: true, expires_in: interval.seconds)

      self.class.perform_in(interval.seconds)
    end
  end
end
