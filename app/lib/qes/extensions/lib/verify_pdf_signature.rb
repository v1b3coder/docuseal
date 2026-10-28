# frozen_string_literal: true

module Qes
  module Extensions
    module Lib
      module VerifyPdfSignature
        def call(io, trusted_certs)
          return super unless Qes.enabled?

          io.binmode if io.respond_to?(:binmode)
          io.rewind
          Qes::PdfiumTrust.report(io, trusted_certs)
        end
      end
    end
  end
end
