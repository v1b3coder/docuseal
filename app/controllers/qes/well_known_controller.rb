# frozen_string_literal: true

module Qes
  # `.well-known/apple-app-site-association` pro iOS Universal Links (SPEC § 6.6).
  # AASA nemá příponu, takže statika by ho poslala jako application/octet-stream;
  # proto ho servíruje controller s Content-Type: application/json.
  #
  # Android App Links tu záměrně nejsou: `assetlinks.json` váže odkaz na podpis
  # konkrétního APK a host je zapečený v buildu, takže pro self-hosted instanci
  # nemá smysl. Android jde přes custom scheme `dokulachtan://sign` a systémový
  # chooser — výběr aplikace necháváme na uživateli (docs/24, #18.1).
  class WellKnownController < ApplicationController
    include Qes::ControllerConcern

    skip_before_action :authenticate_user!
    skip_authorization_check
    # Na čerstvé instalaci (žádný User) by `maybe_redirect_to_setup` vrátil
    # 302 na /setup a iOS Universal Links verifikace by selhala (SPEC § 6.6).
    skip_before_action :maybe_redirect_to_setup

    def apple_app_site_association
      team_id = Qes::Config[:ios_team_id].presence || 'TEAMID'

      render json: {
        applinks: {
          details: [
            { appID: "#{team_id}.cz.dokulachtan.signer", paths: ['/qes/sign', '/qes/app'] }
          ]
        }
      }
    end
  end
end
