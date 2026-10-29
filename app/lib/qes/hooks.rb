# frozen_string_literal: true

module Qes
  # Explicitní hooky do upstream metod. `nil` znamená "pokračuj upstreamem";
  # non-nil znamená "nahraď výsledek". Nikdy nekopírují tělo upstream metody.
  module Hooks
    module_function

    def pdf_signatures(io, trusted_certs)
      return unless Qes.enabled?

      io.binmode if io.respond_to?(:binmode)
      io.rewind
      Qes::PdfiumTrust.report(io, trusted_certs)
    end

    def audit_page(composer, submission)
      return unless Qes.active_for?(submission)

      Qes::AuditPage.append(composer, submission)
    end

    def finalize_values(submitter, required_field_uuids_acc: Set.new)
      return unless Qes.active_for?(submitter.submission)

      Qes::SigningValues.finalize!(submitter, required_field_uuids_acc:)

      submitter
    end
  end
end
