module Api
  module V1
    module VoiceCatalog
      class LanguagesController < ApiController
        def index
          render json: ElevenlabsVoiceCatalog.new.languages, status: :ok
        end

        def dialects
          render json: ElevenlabsVoiceCatalog.new.dialects(params[:id]), status: :ok
        end
      end
    end
  end
end
