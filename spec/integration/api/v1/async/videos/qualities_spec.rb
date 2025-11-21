require 'swagger_helper'

RSpec.describe 'api/v1/async/videos/qualities', type: :request do
  include_context "ffmpeg video api"
  include_context "admin"

  path '/api/v1/async/videos/qualities' do
    post('Create a video quality') do
      tags 'Videos - Qualities'
      description 'Creates a new video quality with the specified transcoding profile and external video link. Enqueues an async job to encode the video.'
      consumes 'application/json'
      produces 'application/json'
      security [ bearer_auth: [] ]

      parameter name: :external_video_link, in: :query, type: :string, required: true, description: 'URL of the external video to be transcoded'
      parameter name: :transcoding_profile_label, in: :query, type: :string, required: true, description: 'Label of the transcoding profile to use (e.g., "720p", "1080p")'

      response(201, 'Quality created successfully') do
        schema type: :object,
          properties: {
            id: { type: :integer, description: 'ID of the created quality' },
            label: { type: :string, description: 'Label of the transcoding profile' },
            status: { type: :string, description: 'Current status of the video quality' }
          },
          required: [ 'id', 'label', 'status' ]

        let(:transcoding_profile) { create(:transcoding_profile, label: "720p") }
        let(:external_video_link) { "https://example.com/video.mp4" }
        let(:transcoding_profile_label) { transcoding_profile.label }
        let(:Authorization) { "Bearer #{auth_headers['Authorization']&.split(' ')&.last}" }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(data).to include('id', 'label', 'status')
        end
      end

      response(404, 'Transcoding profile not found') do
        schema type: :object,
          properties: {
            error: { type: :string }
          }

        let(:transcoding_profile) { create(:transcoding_profile, label: "720p") }
        let(:external_video_link) { "https://example.com/video.mp4" }
        let(:transcoding_profile_label) { "nonexistent" }
        let(:Authorization) { "Bearer #{auth_headers['Authorization']&.split(' ')&.last}" }

        run_test!
      end

      response(401, 'Unauthorized') do
        schema type: :object,
          properties: {
            error: { type: :string }
          }

        let(:external_video_link) { "https://example.com/video.mp4" }
        let(:transcoding_profile_label) { "720p" }

        run_test!
      end
    end
  end

  path '/api/v1/async/videos/qualities/{id}' do
    parameter name: :id, in: :path, type: :integer, required: true, description: 'ID of the video quality'

    get('Retrieve a video quality') do
      tags 'Videos - Qualities'
      description 'Retrieves the status and details of a specific video quality, including the transcoded video URL if available.'
      produces 'application/json'
      security [ bearer_auth: [] ]

      response(200, 'Quality found successfully') do
        schema type: :object,
          properties: {
            status: { type: :string, description: 'Current status of the video quality' },
            url: { type: :string, nullable: true, description: 'URL of the transcoded video file (null if not yet processed)' },
            label: { type: :string, description: 'Label of the transcoding profile used' }
          },
          required: [ 'status', 'url', 'label' ]

        let(:transcoding_profile) { create(:transcoding_profile, label: "1080p") }
        let(:quality) { create(:quality, transcoding_profile: transcoding_profile) }
        let(:id) { quality.id }
        let(:Authorization) { "Bearer #{auth_headers['Authorization']&.split(' ')&.last}" }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(data).to include('status', 'url', 'label')
          expect(data['label']).to eq(transcoding_profile.label)
        end
      end

      response(404, 'Quality not found') do
        schema type: :object,
          properties: {
            error: { type: :string }
          }

        let(:id) { 999999 }
        let(:Authorization) { "Bearer #{auth_headers['Authorization']&.split(' ')&.last}" }

        run_test!
      end

      response(401, 'Unauthorized') do
        schema type: :object,
          properties: {
            error: { type: :string }
          }

        let(:transcoding_profile) { create(:transcoding_profile, label: "1080p") }
        let(:quality) { create(:quality, transcoding_profile: transcoding_profile) }
        let(:id) { quality.id }

        run_test!
      end
    end
  end
end
