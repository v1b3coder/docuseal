# frozen_string_literal: true

module Qes
  # Test CRL pro staging (SPEC § 7.4): testovací certifikáty mají CRL DP
  # na staging host, aby fail-closed LTV šlo ověřit i bez přístupu na 127.0.0.1.
  # V produkci je `QES_TEST_CRL_PATH` prázdná → 404.
  class TestCrlController < ApplicationController
    include Qes::ControllerConcern

    skip_before_action :authenticate_user!
    skip_authorization_check
    skip_before_action :maybe_redirect_to_setup

    def show
      path = Qes::Config[:test_crl_path]

      return head :not_found if path.blank? || !File.file?(path)

      send_file path, type: 'application/pkix-crl', disposition: 'inline'
    end
  end
end
