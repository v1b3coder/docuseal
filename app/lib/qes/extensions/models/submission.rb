# frozen_string_literal: true

module Qes
  module Extensions
    module Models
      module Submission
        extend ActiveSupport::Concern

        prepended do
          before_validation :maybe_preserve_qes_order, on: :create
        end

        private

        # QES řetězení podpisů vyžaduje striktní pořadí (SPEC § 4.6).
        # `QES_ENABLED=false` je feature gate (nález #10): s vypnutým QES
        # zůstává upstream pořadí, ne naše vynucené `preserved`.
        def maybe_preserve_qes_order
          return unless Qes.enabled?
          return if template.blank? || template.fields.none? { |field| field['type'] == 'qes' }

          self.submitters_order = :preserved
        end
      end
    end
  end
end
