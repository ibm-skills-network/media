if Rails.env.development?
  Settings.add_source!("#{Rails.root}/config/settings/development.local.yaml.dec")
  Settings.add_source!("#{Rails.root}/config/settings/development.local.yml")
  Settings.reload!
end
