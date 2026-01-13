#!/bin/bash
export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"
export RAILS_ENV=production
export DISABLE_SPRING=1

cd /var/mahis/BHT-EMR-API/
bundle exec rails couchdb:start_all_listeners
