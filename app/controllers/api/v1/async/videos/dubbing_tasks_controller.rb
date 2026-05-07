module Api
    module V1
        module Async
            module Videos
                class DubbingTasksController < ApiController
                    before_action :set_dubbing_task, only: %w[show]

                    def show
                        render json: {
                            status: @dubbing_task.status,
                            error_message: @dubbing_task.error_message
                        }, status: :ok
                    end

                    def create
                        task = DubbingTask.create!(
                            video_url: dubbing_params[:video_url],
                            language: dubbing_params[:language],
                            dialect: dubbing_params[:dialect]
                        )

                        render json: { id: task.id, status: task.status }, status: :created
                    end

                    private

                    def set_dubbing_task
                        @dubbing_task = DubbingTask.find(params[:id])
                    end


                    def dubbing_params
                        params.require(:dubbing_task).permit(:video_url, :language, :dialect)
                    end
                end
            end
        end
    end
end
