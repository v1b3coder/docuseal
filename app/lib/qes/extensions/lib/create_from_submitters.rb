# frozen_string_literal: true

module Qes
  module Extensions
    module Lib
      module CreateFromSubmitters
        def merge_submitters_and_fields(submitter_attrs, template_submitters, template_fields)
          super(submitter_attrs, template_submitters, template_fields.deep_dup)
        end

        def assign_field_attrs(field, attrs)
          # `required` i `level` QES pole jsou zmrazené ve snapshotu submissionu
          # (N1, #16); API je nesmí změnit. Čtou se ze submissionu, ne ze
          # šablony: při vzniku je snapshot zkopírovaný z šablony a pak už se
          # nemění, takže úprava šablony ani API nemá na rozběhnutou submission
          # vliv.
          # `QES_ENABLED=false` je feature gate (nález #10): s vypnutým QES
          # platí upstream pravidlo a hodnota z API se použije.
          snapshot_required = field['required']
          snapshot_level = field.dig('preferences', 'level')
          result = super

          return result unless Qes.enabled? && field['type'] == 'qes'

          field['required'] = snapshot_required if attrs.key?('required')

          if attrs['preferences'].present?
            preferences = (field['preferences'] || {}).except('level')
            preferences['level'] = snapshot_level if snapshot_level.present?
            field['preferences'] = preferences.presence
          end

          result
        end
      end
    end
  end
end
