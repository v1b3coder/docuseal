# frozen_string_literal: true

module Qes
  # Web fallback stránka `/qes/app` a `/qes/sign` (SPEC § 6.4): QR kód
  # s custom scheme a tlačítko pro otevření appky. Bez citlivých dat.
  class AppController < ApplicationController
    include Qes::ControllerConcern

    skip_before_action :authenticate_user!
    skip_authorization_check
    layout 'form'

    def show
      @token = params[:token].to_s
      @session = Qes::Token.find(@token)
      @custom_scheme_link = Qes::Link.custom_scheme(request, @token)
      @document_name = @session&.submission&.name.presence || @session&.submission&.template&.name
      @signer_name = @session&.submitter&.name
      @expires_at = @session&.expires_at
      # Android App Links zrušeny (#18.1): QR i tlačítko míří na custom scheme,
      # takže appku vybírá systémový chooser.
      @qr_svg = RQRCode::QRCode.new(@custom_scheme_link, level: :m).as_svg(viewbox: true)
    end
  end
end
