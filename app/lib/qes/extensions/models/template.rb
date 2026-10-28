# frozen_string_literal: true

module Qes
  module Extensions
    module Models
      module Template
        extend ActiveSupport::Concern

        prepended do
          validate :qes_signing_order
        end

        private

        def qes_signing_order
          return unless fields.any? { |field| field['type'] == 'qes' }

          signers = submitters.reject { |submitter| submitter['is_viewer'] }

          unless signers.all? { |signer| fields.any? { |field| field['submitter_uuid'] == signer['uuid'] && field['type'] == 'qes' } }
            errors.add(:fields, 'qes_all_signers_required')
          end

          return if signers.size <= 1

          orders = signers.each_with_index.map { |signer, index| signer['order'].presence || index }

          errors.add(:fields, 'qes_parallel_signers_not_allowed') if orders.size != orders.uniq.size

          return if preferences['submitters_order'] == 'preserved' || signers.all? { |signer| signer['order'].present? }

          errors.add(:fields, 'qes_signing_order_required')
        end
      end
    end
  end
end
