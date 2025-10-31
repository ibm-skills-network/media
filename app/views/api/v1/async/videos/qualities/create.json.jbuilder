json.qualities @qualities do |quality|
  json.id quality.id
  json.label quality.label
end
json.message "Video uploaded successfully"
json.status "success"
