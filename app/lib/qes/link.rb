# frozen_string_literal: true

module Qes
  # Odkaz do appky (SPEC § 6): universal link i fallback stránka mají stejnou
  # logiku (`QES_PUBLIC_BASE_URL` + token), jen jinou cestu (M3).
  # Custom scheme navíc nese origin serveru, aby appka nemusela sahat do
  # Nastavení (to je jen pro přímý podpis a ověření PDF).
  module Link
    module_function

    def call(request, path, token)
      "#{origin(request)}#{path}?token=#{CGI.escape(token)}"
    end

    def custom_scheme(request, token)
      "#{Qes::Config[:deep_link_base]}?token=#{CGI.escape(token)}&server=#{CGI.escape(origin(request))}"
    end

    def origin(request)
      (Qes::Config[:public_base_url].presence || request.base_url).chomp('/')
    end
  end
end
