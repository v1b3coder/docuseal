# frozen_string_literal: true

# Jedna připravená podpisová revize na submission (S3). Kontrola v controlleru
# je jen v Ruby; index je poslední pojistka, když se dva requesty sejdou mezi
# předkontrolou a zámkem.
class AddOneActiveSessionIndexToQesSessions < ActiveRecord::Migration[8.1]
  ACTIVE_STATES = %w[prepared awaiting_app app_opened awaiting_signature].freeze

  def up
    # Duplicity z doby před opravou jsou už rozbitá data (dvě větve PDF).
    # Ponecháme nejnovější session — tu by použil `ResultAttachments` — a
    # starší označíme jako expired, aby je index nezablokoval.
    execute <<~SQL.squish
      UPDATE qes_sessions
      SET state = 'expired', failure_code = 'expired',
          expired_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
      WHERE state IN (#{quoted_states})
        AND id NOT IN (
          SELECT MAX(id) FROM qes_sessions
          WHERE state IN (#{quoted_states})
          GROUP BY submission_id
        )
    SQL

    predicate = "state IN (#{quoted_states})"
    add_index :qes_sessions, :submission_id, unique: true, where: predicate,
                                             name: 'index_qes_sessions_one_active_per_submission'
  end

  def down
    remove_index :qes_sessions, name: 'index_qes_sessions_one_active_per_submission'
  end

  private

  def quoted_states
    ACTIVE_STATES.map { |state| "'#{state}'" }.join(',')
  end
end
