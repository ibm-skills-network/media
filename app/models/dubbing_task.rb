class DubbingTask < ApplicationRecord
    enum :status, {
        pending: "pending",
        processing: "processing",
        success: "success",
        failed: "failed"
    }, default: "pending"
end
