# frozen_string_literal: true

# QES routy mimo `config/routes.rb`; `prepend` je vyhodnocen při každém reloadu.
Rails.application.routes.prepend do
  namespace :api, defaults: { format: :json } do
    resources :qes_documents, only: %i[create], path: 'qes/documents'
    resources :qes_verifications, only: %i[create], path: 'qes/verify'
    post 'qes/verified_documents', to: 'qes_verifications#store'
  end

  namespace :qes do
    resources :sessions, only: %i[show], param: :token, path: 'sessions' do
      member do
        get :document
        post :certificate
        post :complete
        post :complete_submission
        post :abort
      end
    end
    get 'sign', to: 'app#show'
    get 'app', to: 'app#show'
  end

  get '.well-known/apple-app-site-association', to: 'qes/well_known#apple_app_site_association'
  get '.well-known/assetlinks.json', to: 'qes/well_known#assetlinks'
  get 'qes-test/root.crl', to: 'qes/test_crl#show'

  get 'templates/:template_id/qes_verification', to: 'templates_qes_verifications#show',
      as: :template_qes_verification

  post 's/:submit_form_slug/qes_sessions', to: 'qes/form_sessions#create'
  get 's/:submit_form_slug/qes_sessions/:id', to: 'qes/form_sessions#show'
  post 's/:submit_form_slug/qes_sessions/:id/cancel', to: 'qes/form_sessions#cancel'
end
