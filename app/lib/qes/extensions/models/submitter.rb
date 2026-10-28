# frozen_string_literal: true

module Qes
  module Extensions
    module Models
      module Submitter
        extend ActiveSupport::Concern

        prepended do
          has_many :qes_sessions, dependent: :destroy

          before_validation :ensure_qes_completion,
                            if: -> { Qes.enabled? && completed_at_changed? && completed_at.present? }
          before_validation :ensure_qes_values, if: -> { Qes.enabled? && values_changed? }
        end

        def with_signature_fields?
          super || qes_signature_field?
        end

        private

        def qes_signature_field?
          Qes.active_for?(submission) &&
            Qes.template_fields(submission).any? do |field|
              field['submitter_uuid'] == uuid && field['type'] == 'qes'
            end
        end

        def ensure_qes_completion
          if Qes.missing_required_sessions(self).present?
            raise Submitters::SubmitValues::ValidationError, 'Required QES signatures are missing'
          end

          Qes::ValueValidator.call(values, self)
        end

        def ensure_qes_values
          Qes::ValueValidator.call(values, self)
        end
      end
    end
  end
end
