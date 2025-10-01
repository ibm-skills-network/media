# Prevent Rails from trying to enable plpgsql extension
# plpgsql is built-in to PostgreSQL and doesn't need explicit enabling
# This is necessary for production environments that don't allow pg_catalog access

ActiveSupport.on_load(:active_record) do
  module DisablePlpgsqlExtension
    def extensions
      # Return empty array to prevent Rails from trying to enable any extensions
      []
    end
  end

  ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(DisablePlpgsqlExtension)
end
