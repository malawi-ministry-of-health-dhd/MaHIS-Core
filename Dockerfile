FROM ruby:3.2

# Set DNS to use Google's public DNS as a fallback
RUN echo "nameserver 8.8.8.8" >> /etc/resolv.conf

# Install dependencies with retry mechanism
RUN apt-get update -qq || (sleep 10 && apt-get update -qq) && \
    apt-get install -y \
    build-essential \
    default-libmysqlclient-dev \
    mariadb-client \
    nodejs \
    npm \
    curl \
    net-tools \
    netcat \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install passenger
RUN gem install passenger

# Set up working directory
WORKDIR /app

# Copy Gemfile and Gemfile.lock
COPY Gemfile Gemfile.lock ./

# Install gems with retry
RUN bundle install || (gem install bundler && bundle install)

# Copy the rest of the application
COPY . .

# Expose port 3000
EXPOSE 3000

# Set environment variables
ENV RAILS_ENV=development
ENV RAILS_LOG_TO_STDOUT=true

# Install foreman to run multiple processes
RUN gem install foreman

# Create entrypoint script
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Wait for MySQL to be ready\n\
if [ -n "$DATABASE_HOST" ]; then\n\
  echo "Waiting for MySQL..."\n\
  while ! nc -z $DATABASE_HOST ${DATABASE_PORT:-3306}; do\n\
    sleep 1\n\
  done\n\
  echo "MySQL is up and running!"\n\
fi\n\
\n\
# Remove a potentially pre-existing server.pid for Rails\n\
rm -f tmp/pids/server.pid\n\
\n\
# Run database migrations if needed\n\
if [ "$RAILS_ENV" = "development" ] || [ "$RAILS_ENV" = "test" ]; then\n\
  bundle exec rails db:create db:migrate 2>/dev/null || echo "Database migrations not needed"\n\
fi\n\
\n\
# Start Redis and Sidekiq in background if needed\n\
if [ "$ENABLE_SIDEKIQ" = "true" ]; then\n\
  redis-server --daemonize yes\n\
  bundle exec sidekiq -C config/sidekiq.yml &\n\
fi\n\
\n\
# Execute the main command\n\
exec "$@"' > /app/entrypoint.sh

RUN chmod +x /app/entrypoint.sh

# Set entry point
ENTRYPOINT ["/app/entrypoint.sh"]

# Start Rails server
CMD ["rails", "server", "-b", "0.0.0.0"]