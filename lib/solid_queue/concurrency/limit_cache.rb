# frozen_string_literal: true

module SolidQueue
  module Concurrency
    # One in-process memo of evaluated `to:` procs for this Ruby process.
    # Threads in the same process share it (`MemoryStore` is Monitor-synchronized).
    # Forked workers do not — each child has its own store. Not `Rails.cache`.
    class LimitCache
      class << self
        def fetch(key, generation:, &block)
          ttl = SolidQueue.concurrency_limit_cache_ttl
          return yield unless ttl

          cached = store.read(key)
          if cached && cached[:generation] == generation
            cached[:limit]
          else
            value = yield
            store.write(key, { limit: value, generation: generation }, expires_in: ttl)
            value
          end
        end

        def delete(key)
          store.delete(key)
        end

        def clear
          store.clear
        end

        private
          def store
            @store ||= ActiveSupport::Cache::MemoryStore.new
          end
      end
    end
  end
end
