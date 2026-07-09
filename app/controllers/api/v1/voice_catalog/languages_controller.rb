module Api
  module V1
    module VoiceCatalog
      class LanguagesController < ApiController
        def index
          render json: ElevenlabsVoiceCatalog.new.languages, status: :ok
        end
      end
    end
  end
end
