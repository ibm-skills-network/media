class DubbingTask < ApplicationRecord
    enum :status, {
        pending: "pending",
        processing: "processing",
        success: "success",
        failed: "failed"
    }, default: "pending"

    VOICES = {
        "peninsular" => {
        "man"   => [ "851ejYcv2BoNPjrkw93G", "eEyWolF7iBpMA65GbtAm", "SKjgN71N3MeGl4r2JbRt" ],
        "woman" => [ "AxFLn9byyiDbMn5fmyqu", "Oe0GElYvnDDV5qP1vbE2", "gD1IexrzCvsXPHUuT0s3" ]
        },
        "latin-american" => {
        "man"   => [ "YExhVa4bZONzeingloMX", "t3eeeqhBjrUqcrPvDqUn", "4XUsiqPDK4UACIM2BILe" ],
        "woman" => [ "cIBxLwfshLYhRB9lCXEg", "nTkjq09AuYgsNR8E4sDe", "nbcvT3C2tyOd2OsRAtUf" ]
        }
    }.freeze

    def voice_for(speaker)
        gender = segments.find { |s| s["speaker"] == speaker }&.dig("gender") || "man"
        voice_pool = VOICES.dig(dialect, gender) || VOICES["latin-american"]["man"]
        voice_pool[speaker.gsub("SPEAKER_", "").to_i % voice_pool.length]
    end
end
